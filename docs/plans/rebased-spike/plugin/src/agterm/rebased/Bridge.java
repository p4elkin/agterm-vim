package agterm.rebased;

import com.intellij.ide.impl.ProjectUtil;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.application.ModalityState;
import com.intellij.openapi.command.WriteCommandAction;
import com.intellij.openapi.fileEditor.FileDocumentManager;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.project.ProjectManager;
import com.intellij.openapi.vfs.LocalFileSystem;
import com.intellij.openapi.wm.WindowManager;
import com.intellij.ui.mac.foundation.Foundation;
import com.intellij.ui.mac.foundation.ID;
import com.intellij.ui.mac.foundation.MacUtil;
import java.awt.AWTEvent;
import java.awt.Dialog;
import java.awt.Frame;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.event.WindowEvent;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.function.BiFunction;

// The host reaches this object through System.getProperties(), typed as a JDK interface, so it never needs
// the plugin class loader. Events go back through hostEvent, which the host binds with RegisterNatives.
public final class Bridge implements BiFunction<String, String, String> {
  static native void hostEvent(String kind, String payload);

  private static final Object lock = new Object();
  private static final List<String[]> pending = new ArrayList<>();
  private static volatile boolean hostAttached;

  static void log(String s) { System.err.println("[agterm-bridge] " + s); }

  static void install() {
    System.getProperties().put("agterm.rebased.bridge", new Bridge());
    Toolkit.getDefaultToolkit().addAWTEventListener(e -> onWindowEvent((WindowEvent) e), AWTEvent.WINDOW_EVENT_MASK);
    if (Boolean.getBoolean("agterm.spike.keys")) {  // spike only: report keys that reach Java
      Toolkit.getDefaultToolkit().addAWTEventListener(e -> {
        var k = (java.awt.event.KeyEvent) e;
        if (k.getID() == java.awt.event.KeyEvent.KEY_PRESSED)
          emit("key", java.awt.event.KeyEvent.getKeyText(k.getKeyCode()) + "\t" + k.getModifiersEx());
      }, AWTEvent.KEY_EVENT_MASK);
    }
    emit("ready", "");
  }

  static void emit(String kind, String payload) {
    synchronized (lock) {
      if (!hostAttached) { pending.add(new String[]{kind, payload}); return; }
    }
    try { hostEvent(kind, payload); } catch (UnsatisfiedLinkError e) { log("hostEvent unbound: " + e); }
  }

  private static long windowNumber(Window w) {
    ID id = MacUtil.getWindowFromJavaWindow(w);
    if (id == null || id.longValue() == 0) return 0;
    return Foundation.invoke(id, "windowNumber").longValue();
  }

  private static Project projectOf(Window w) {
    for (Project p : ProjectManager.getInstance().getOpenProjects()) {
      if (WindowManager.getInstance().getFrame(p) == w) return p;
    }
    return null;
  }

  private static void onWindowEvent(WindowEvent e) {
    Window w = e.getWindow();
    if (e.getID() == WindowEvent.WINDOW_OPENED) {
      long n = windowNumber(w);
      if (w instanceof Frame && w.getClass().getName().contains("Welcome")) {
        emit("windowOpened", n + "\twelcome");
      } else if (w instanceof Frame) {
        // A project frame is shown before its project is attached to it, so poll briefly for the project.
        reportFrame(w, n, 0);
      } else {
        emit("windowOpened", n + "\t" + (w instanceof Dialog ? "dialog" : "popup"));
      }
    } else if (e.getID() == WindowEvent.WINDOW_CLOSED && w instanceof Frame) {
      emit("frameClosed", String.valueOf(windowNumber(w)));
    }
  }

  private static void reportFrame(Window w, long n, int attempt) {
    Project p = projectOf(w);
    if (p != null) { emit("frameOpened", p.getBasePath() + "\t" + n); return; }
    if (attempt >= 50) { emit("windowOpened", n + "\tframe " + w.getClass().getName()); return; }
    var t = new javax.swing.Timer(100, e -> reportFrame(w, n, attempt + 1));
    t.setRepeats(false);
    t.start();
  }

  private static List<Frame> projectFrames(String dir) {
    List<Frame> out = new ArrayList<>();
    for (Project p : ProjectManager.getInstance().getOpenProjects()) {
      if (!dir.isEmpty() && !dir.equals(p.getBasePath())) continue;
      var f = WindowManager.getInstance().getFrame(p);
      if (f != null) out.add(f);
    }
    return out;
  }

  private static void later(Runnable r) { ApplicationManager.getApplication().invokeLater(r, ModalityState.any()); }

  // Model changes need a write-safe context, which `any()` is not. Hop to the EDT first, then queue the
  // change under the modality current there, so it also runs while a modal dialog is open.
  private static void writeSafe(Runnable r) {
    later(() -> ApplicationManager.getApplication().invokeLater(r, ModalityState.current()));
  }

  private static String findMenuish(java.awt.Container c) {
    var found = new ArrayList<String>();
    java.util.ArrayDeque<java.awt.Component> q = new java.util.ArrayDeque<>(List.of(c));
    while (!q.isEmpty()) {
      var x = q.poll();
      String n = x.getClass().getName();
      if ((n.contains("MainMenu") || n.contains("MenuBar")) && x.isShowing()) found.add(x.getClass().getSimpleName());
      if (x instanceof java.awt.Container k) q.addAll(List.of(k.getComponents()));
    }
    return found.toString();
  }

  private static boolean onDisk(String path, String text) {
    try { return java.nio.file.Files.readString(Path.of(path)).equals(text); }
    catch (java.io.IOException e) { return false; }
  }

  @Override public String apply(String cmd, String arg) {
    switch (cmd) {
      case "hello" -> {
        List<String[]> flush;
        synchronized (lock) { hostAttached = true; flush = new ArrayList<>(pending); pending.clear(); }
        for (String[] ev : flush) hostEvent(ev[0], ev[1]);
        return "ok";
      }
      case "open" -> { writeSafe(() -> ProjectUtil.openOrImport(Path.of(arg), null, true)); return "ok"; }
      case "hide" -> { later(() -> projectFrames(arg).forEach(f -> f.setVisible(false))); return "ok"; }
      case "show" -> { later(() -> projectFrames(arg).forEach(f -> { f.setVisible(true); f.toFront(); })); return "ok"; }
      case "saveAll" -> {
        // saveAllDocuments returns before the bytes are on disk, so the answer waits for the files themselves.
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        var pending = new java.util.concurrent.atomic.AtomicReference<List<String[]>>();
        var done = new CountDownLatch(1);
        writeSafe(() -> {
          var fdm = FileDocumentManager.getInstance();
          List<String[]> want = new ArrayList<>();
          for (var doc : fdm.getUnsavedDocuments()) {
            var vf = fdm.getFile(doc);
            if (vf != null && vf.isInLocalFileSystem()) want.add(new String[]{vf.getPath(), doc.getText()});
          }
          fdm.saveAllDocuments();
          pending.set(want);
          done.countDown();
        });
        try {
          if (!done.await(2, TimeUnit.SECONDS)) return "timeout before save";
          for (String[] f : pending.get()) {
            while (!onDisk(f[0], f[1])) {
              if (System.nanoTime() > deadline) return "timeout writing " + f[0];
              Thread.sleep(20);
            }
          }
          return "ok " + pending.get().size();
        } catch (InterruptedException e) { return "interrupted"; }
      }
      // Spike-only commands below drive the checks; the shipped bridge has none of them.
      case "edit" -> {
        writeSafe(() -> {
          var vf = LocalFileSystem.getInstance().refreshAndFindFileByPath(arg);
          var doc = vf == null ? null : FileDocumentManager.getInstance().getDocument(vf);
          if (doc == null) { log("edit: no document for " + arg); return; }
          WriteCommandAction.runWriteCommandAction(null, () -> doc.insertString(0, "EDIT\n"));
          log("edit: inserted into " + arg);
        });
        return "ok";
      }
      case "selfResize" -> {
        later(() -> projectFrames("").forEach(f -> f.setBounds(f.getX() + 60, f.getY() + 60, 520, 380)));
        return "ok";
      }
      case "zoom" -> { later(() -> projectFrames("").forEach(f -> f.setExtendedState(Frame.MAXIMIZED_BOTH))); return "ok"; }
      case "minimize" -> { later(() -> projectFrames("").forEach(f -> f.setExtendedState(Frame.ICONIFIED))); return "ok"; }
      case "dialog" -> {
        later(() -> com.intellij.openapi.ui.Messages.showInfoMessage("spike dialog", "agterm spike"));
        return "ok";
      }
      case "menuInfo" -> {
        var out = new StringBuilder();
        for (Frame f : projectFrames("")) {
          var bar = f instanceof javax.swing.JFrame jf ? jf.getJMenuBar() : null;
          out.append("frame menu bar ").append(bar == null ? "none" : bar.getClass().getSimpleName() + " with "
              + bar.getMenuCount() + " menus, showing " + bar.isShowing());
          out.append("; menu-like components: ").append(findMenuish(f));
        }
        return out.toString();
      }
      case "closeDialogs" -> {
        later(() -> { for (Window w : Window.getWindows()) if (w instanceof Dialog && w.isVisible()) w.dispose(); });
        return "ok";
      }
      default -> { return "unknown command " + cmd; }
    }
  }
}
