package agterm.rebased;

import com.intellij.ide.impl.ProjectUtil;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.application.ModalityState;
import com.intellij.openapi.fileEditor.FileDocumentManager;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.project.ProjectManager;
import com.intellij.openapi.wm.WindowManager;
import com.intellij.openapi.wm.impl.IdeFrameImpl;
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
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.function.BiFunction;

// The host reaches this object through System.getProperties(), typed as a JDK interface, so it never needs
// the plugin class loader. Events go back through hostEvent, which the host binds with RegisterNatives.
public final class Bridge implements BiFunction<String, String, String> {
  static final String PROPERTY = "agterm.rebased.bridge";
  static native void hostEvent(String kind, String payload);

  private static final Object lock = new Object();
  private static final List<String[]> pending = new ArrayList<>();
  private static volatile boolean hostAttached;
  private static final Map<Window, String> frameProjects = new IdentityHashMap<>();

  static void openedProject(Window window, String project, long number) {
    frameProjects.put(window, project);
    emit("frameOpened", project + "\t" + number);
  }

  static void closedProject(Window window) {
    String project = frameProjects.remove(window);
    if (project != null) emit("frameClosed", project);
  }

  static void windowOpened(Window window, long number, String kind) {
    emit("windowOpened", number + "\t" + kind + "\t" + ownerProject(window));
  }

  private static String ownerProject(Window window) {
    for (Window owner = window; owner != null; owner = owner.getOwner()) {
      String project = frameProjects.get(owner);
      if (project != null) return project;
    }
    for (Window owner = window; owner != null; owner = owner.getOwner()) {
      if (!(owner instanceof Frame)) continue;
      Project project = projectOf(owner);
      if (project != null && project.getBasePath() != null) return project.getBasePath();
    }
    return "";
  }

  static void log(String s) { System.err.println("[agterm-bridge] " + s); }

  static void install() {
    System.getProperties().put(PROPERTY, new Bridge());
    Toolkit.getDefaultToolkit().addAWTEventListener(e -> onWindowEvent((WindowEvent) e), AWTEvent.WINDOW_EVENT_MASK);
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

  // A project already open (one IntelliJ reopened before this plugin listened) gets no new window event.
  private static void open(String dir) {
    for (Project p : ProjectManager.getInstance().getOpenProjects()) {
      var frame = WindowManager.getInstance().getFrame(p);
      if (frame != null && p.getBasePath() != null && sameDirectory(p.getBasePath(), dir)) {
        openedProject(frame, p.getBasePath(), windowNumber(frame));
        return;
      }
    }
    ProjectUtil.openOrImport(Path.of(dir), null, true);
  }

  static Project openProject(String dir) {
    for (Project p : ProjectManager.getInstance().getOpenProjects()) {
      if (p.getBasePath() != null && sameDirectory(p.getBasePath(), dir)) return p;
    }
    return null;
  }

  // `<base>\t<head>\t<0|1>\t<project>`: the project is last because a path may hold a tab.
  static String[] diffFields(String arg) {
    String[] fields = arg.split("\t", 4);
    return fields.length == 4 ? fields : null;
  }

  private static boolean sameDirectory(String a, String b) {
    try { return Path.of(a).toRealPath().equals(Path.of(b).toRealPath()); }
    catch (java.io.IOException e) { return Path.of(a).normalize().equals(Path.of(b).normalize()); }
  }

  private static void onWindowEvent(WindowEvent e) {
    Window w = e.getWindow();
    if (e.getID() == WindowEvent.WINDOW_OPENED) {
      long n = windowNumber(w);
      if (w instanceof Frame && w.getClass().getName().contains("Welcome")) {
        windowOpened(w, n, "welcome");
      } else if (w instanceof IdeFrameImpl) {
        // A project frame is shown before its project is attached to it, so poll for the project. Detached
        // editor and diff windows are other Frames and report at once.
        reportFrame(w, n, 0);
      } else {
        windowOpened(w, n, w instanceof Dialog ? "dialog" : "popup");
      }
    } else if (e.getID() == WindowEvent.WINDOW_CLOSED && w instanceof Frame) {
      closedProject(w);
    }
  }

  private static void reportFrame(Window w, long n, int attempt) {
    if (!w.isDisplayable()) return;
    Project p = projectOf(w);
    if (p != null && p.getBasePath() != null) { openedProject(w, p.getBasePath(), n); return; }
    // A slow project is still a project frame; reported as anything else, the host would show it unfitted.
    if (attempt >= 650) return;
    var t = new javax.swing.Timer(attempt < 50 ? 100 : 1000, e -> reportFrame(w, n, attempt + 1));
    t.setRepeats(false);
    t.start();
  }

  private static List<Frame> projectFrames(String dir) {
    List<Frame> out = new ArrayList<>();
    for (Project p : ProjectManager.getInstance().getOpenProjects()) {
      if (!dir.isEmpty() && (p.getBasePath() == null || !sameDirectory(p.getBasePath(), dir))) continue;
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

  static byte[] savedBytes(String text, String separator, Charset charset, byte[] bom) {
    if (charset.equals(StandardCharsets.UTF_16) && bom != null && bom.length == 2) {
      charset = bom[0] == (byte)0xff && bom[1] == (byte)0xfe ? StandardCharsets.UTF_16LE : StandardCharsets.UTF_16BE;
    }
    byte[] body = text.replace("\n", separator == null ? "\n" : separator).getBytes(charset);
    if (bom == null || bom.length == 0) return body;
    if (body.length >= bom.length && Arrays.equals(body, 0, bom.length, bom, 0, bom.length)) return body;
    byte[] bytes = Arrays.copyOf(bom, bom.length + body.length);
    System.arraycopy(body, 0, bytes, bom.length, body.length);
    return bytes;
  }

  static boolean onDisk(String path, byte[] expected) {
    try { return Arrays.equals(java.nio.file.Files.readAllBytes(Path.of(path)), expected); }
    catch (java.io.IOException e) { return false; }
  }

  private record SavedFile(String path, byte[] bytes) {}

  @Override public String apply(String cmd, String arg) {
    switch (cmd) {
      case "hello" -> {
        // The host holds its own reference by now. A non-String system property breaks code that copies them
        // as strings: IntelliJ IDEA's Maven import fails with an NPE before any project opens.
        System.getProperties().remove(PROPERTY);
        List<String[]> flush;
        synchronized (lock) { hostAttached = true; flush = new ArrayList<>(pending); pending.clear(); }
        for (String[] ev : flush) hostEvent(ev[0], ev[1]);
        return "ok";
      }
      case "open" -> { writeSafe(() -> open(arg)); return "ok"; }
      case "hide" -> { later(() -> projectFrames(arg).forEach(f -> f.setVisible(false))); return "ok"; }
      case "show" -> { later(() -> projectFrames(arg).forEach(f -> { f.setVisible(true); f.toFront(); })); return "ok"; }
      case "diff" -> {
        String[] fields = diffFields(arg);
        if (fields == null) return "malformed diff";
        RangeDiff.show(fields[0], fields[1], fields[2].equals("1"), fields[3]);
        return "ok";
      }
      case "saveAll" -> {
        // saveAllDocuments returns before the bytes are on disk, so the answer waits for the files themselves.
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        var pending = new java.util.concurrent.atomic.AtomicReference<List<SavedFile>>();
        var done = new CountDownLatch(1);
        writeSafe(() -> {
          var fdm = FileDocumentManager.getInstance();
          List<SavedFile> want = new ArrayList<>();
          for (var doc : fdm.getUnsavedDocuments()) {
            var vf = fdm.getFile(doc);
            if (vf != null && vf.isInLocalFileSystem()) {
              want.add(new SavedFile(vf.getPath(), savedBytes(doc.getText(), vf.getDetectedLineSeparator(), vf.getCharset(), vf.getBOM())));
            }
          }
          fdm.saveAllDocuments();
          pending.set(want);
          done.countDown();
        });
        try {
          long remaining = deadline - System.nanoTime();
          if (remaining <= 0 || !done.await(remaining, TimeUnit.NANOSECONDS)) return "timeout before save";
          for (SavedFile f : pending.get()) {
            while (!onDisk(f.path(), f.bytes())) {
              if (System.nanoTime() > deadline) return "timeout writing " + f.path();
              Thread.sleep(20);
            }
          }
          return "ok " + pending.get().size();
        } catch (InterruptedException e) { return "interrupted"; }
      }
      default -> { return "unknown command " + cmd; }
    }
  }
}
