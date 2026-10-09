package agterm.rebased;

import com.intellij.openapi.fileEditor.FileEditorManager;
import com.intellij.openapi.fileEditor.OpenFileDescriptor;
import com.intellij.openapi.vfs.LocalFileSystem;

final class OpenFile {
  private OpenFile() {}

  static void show(String request, int line, String path, String dir) {
    Bridge.writeSafe(() -> {
      if (Bridge.superseded(dir, request)) return;
      var project = Bridge.openProject(dir);
      if (project == null) { Bridge.emit("viewFailed", request + "\tno open project at " + dir); return; }
      try {
        var file = LocalFileSystem.getInstance().refreshAndFindFileByPath(path);
        if (file == null || file.isDirectory()) {
          Bridge.emit("viewFailed", request + "\tfile not found: " + path);
          return;
        }
        var descriptor = line == 0 ? new OpenFileDescriptor(project, file) : new OpenFileDescriptor(project, file, line - 1, 0);
        if (FileEditorManager.getInstance(project).openTextEditor(descriptor, true) == null) {
          Bridge.emit("viewFailed", request + "\tfile editor did not open: " + path);
          return;
        }
        Bridge.emit("viewOpened", request + "\t" + path);
      } catch (RuntimeException e) {
        Bridge.emit("viewFailed", request + "\t" + (e.getMessage() == null ? e.toString() : e.getMessage()));
      }
    });
  }
}
