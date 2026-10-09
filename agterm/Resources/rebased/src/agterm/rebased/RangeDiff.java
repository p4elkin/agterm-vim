package agterm.rebased;

import com.intellij.diff.editor.ChainDiffVirtualFile;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.fileEditor.FileEditorManager;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.ui.Messages;
import com.intellij.openapi.vcs.VcsException;
import com.intellij.openapi.vcs.changes.Change;
import com.intellij.openapi.vcs.changes.actions.diff.ChangeDiffRequestProducer;
import com.intellij.openapi.vcs.changes.ui.ChangeDiffRequestChain;
import com.intellij.openapi.vcs.history.VcsDiffUtil;
import com.intellij.openapi.vfs.LocalFileSystem;
import git4idea.GitRevisionNumber;
import git4idea.changes.GitChangeUtils;
import git4idea.history.GitHistoryUtils;
import java.util.ArrayList;
import java.util.List;

// Kept apart from Bridge so the Git plugin's classes load only when a diff is asked for.
final class RangeDiff {
  private RangeDiff() {}

  static void show(String request, String base, String head, boolean mergeBase, boolean workingTree, boolean pane, String dir) {
    ApplicationManager.getApplication().executeOnPooledThread(() -> {
      Project project = Bridge.openProject(dir);
      var root = project == null ? null : LocalFileSystem.getInstance().refreshAndFindFileByPath(project.getBasePath());
      if (root == null) { Bridge.emit("viewFailed", request + "\tno open project at " + dir); return; }
      String title = title(base, head, mergeBase, workingTree);
      try {
        String from = base;
        if (mergeBase) {
          GitRevisionNumber found = GitHistoryUtils.getMergeBase(project, root, base, head);
          if (found == null) throw new VcsException(base + " and " + head + " have no merge base");
          from = found.asString();
        }
        List<Change> changes = new ArrayList<>(workingTree
            ? GitChangeUtils.getDiffWithWorkingDir(project, root, from, null, false)
            : GitChangeUtils.getDiff(project, root, from, head, null));
        if (changes.isEmpty()) { Bridge.emit("viewOpened", request + "\t0"); return; }
        Bridge.writeSafe(() -> {
          if (projectClosed(project, request)) return;
          try {
            if (pane) {
              List<ChangeDiffRequestChain.Producer> producers = new ArrayList<>();
              for (Change change : changes) {
                var producer = ChangeDiffRequestProducer.create(project, change);
                if (producer != null) producers.add(producer);
              }
              if (producers.isEmpty()) throw new IllegalStateException("cannot show any changed file in the diff editor");
              var file = new ChainDiffVirtualFile(new ChangeDiffRequestChain(producers, 0), title);
              if (FileEditorManager.getInstance(project).openFile(file, true).length == 0) {
                throw new IllegalStateException("diff editor did not open");
              }
            } else {
              VcsDiffUtil.showChangesDialog(project, title, changes);
            }
            Bridge.emit("viewOpened", request + "\t" + changes.size());
          } catch (RuntimeException e) {
            failed(project, request, title, pane, e);
          }
        });
      } catch (VcsException | RuntimeException e) {
        Bridge.writeSafe(() -> failed(project, request, title, pane, e));
      }
    });
  }

  static String title(String base, String head, boolean mergeBase, boolean workingTree) {
    if (workingTree && !mergeBase) return base + " (working tree)";
    return base + (mergeBase ? "..." : "..") + head + (workingTree ? " + working tree" : "");
  }

  static boolean projectClosed(Project project, String request) {
    if (!project.isDisposed()) return false;
    Bridge.emit("viewFailed", request + "\tproject closed");
    return true;
  }

  private static void failed(Project project, String request, String title, boolean pane, Exception error) {
    if (projectClosed(project, request)) return;
    String reason = error.getMessage() == null ? error.toString() : error.getMessage();
    Bridge.emit("viewFailed", request + "\t" + reason);
    if (!pane) Messages.showErrorDialog(project, reason, "Diff " + title);
  }
}
