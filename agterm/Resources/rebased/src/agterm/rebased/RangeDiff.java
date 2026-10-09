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
      String title = base + (mergeBase ? "..." : "..") + head;
      try {
        String from = base;
        if (mergeBase) {
          GitRevisionNumber found = GitHistoryUtils.getMergeBase(project, root, base, head);
          if (found == null) throw new VcsException(base + " and " + head + " have no merge base");
          from = found.asString();
        }
        List<Change> changes = new ArrayList<>(workingTree
            ? GitChangeUtils.getDiffWithWorkingDir(project, root, from, null, true)
            : GitChangeUtils.getDiff(project, root, from, head, null));
        if (changes.isEmpty()) { Bridge.emit("viewOpened", request + "\t0"); return; }
        Bridge.writeSafe(() -> {
          try {
            if (pane) {
              List<ChangeDiffRequestChain.Producer> producers = new ArrayList<>();
              for (Change change : changes) {
                var producer = ChangeDiffRequestProducer.create(project, change);
                if (producer == null) throw new IllegalStateException("cannot show a changed file in the diff editor");
                producers.add(producer);
              }
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

  private static void failed(Project project, String request, String title, boolean pane, Exception error) {
    String reason = error.getMessage() == null ? error.toString() : error.getMessage();
    Bridge.emit("viewFailed", request + "\t" + reason);
    if (!pane) Messages.showErrorDialog(project, reason, "Diff " + title);
  }
}
