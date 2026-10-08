package agterm.rebased;

import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.ui.Messages;
import com.intellij.openapi.vcs.VcsException;
import com.intellij.openapi.vcs.changes.Change;
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

  // git runs on a pooled thread; the changes browser, a non-modal dialog of the project frame, on the EDT.
  static void show(String base, String head, boolean mergeBase, String dir) {
    ApplicationManager.getApplication().executeOnPooledThread(() -> {
      Project project = Bridge.openProject(dir);
      var root = project == null ? null : LocalFileSystem.getInstance().refreshAndFindFileByPath(project.getBasePath());
      if (root == null) { Bridge.log("diff: no open project at " + dir); return; }
      String title = base + (mergeBase ? "..." : "..") + head;
      try {
        String from = base;
        if (mergeBase) {
          GitRevisionNumber found = GitHistoryUtils.getMergeBase(project, root, base, head);
          if (found == null) throw new VcsException(base + " and " + head + " have no merge base");
          from = found.asString();
        }
        List<Change> changes = new ArrayList<>(GitChangeUtils.getDiff(project, root, from, head, null));
        String shown = changes.isEmpty() ? title + " (no changes)" : title;
        ApplicationManager.getApplication().invokeLater(() -> VcsDiffUtil.showChangesDialog(project, shown, changes),
            project.getDisposed());
      } catch (VcsException e) {
        ApplicationManager.getApplication().invokeLater(() -> Messages.showErrorDialog(project, e.getMessage(), "Diff " + title),
            project.getDisposed());
      }
    });
  }
}
