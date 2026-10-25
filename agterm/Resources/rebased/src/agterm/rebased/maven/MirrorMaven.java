package agterm.rebased.maven;

import agterm.rebased.Bridge;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.startup.ProjectActivity;
import com.intellij.openapi.util.Disposer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import kotlin.Unit;
import kotlin.coroutines.Continuation;
import org.jetbrains.idea.maven.project.MavenProjectsManager;

/** Points a mirror project's Maven local repository at the synced copy of its host's `~/.m2/repository`. */
public final class MirrorMaven implements ProjectActivity {
  // A cap on re-applies: something that kept resetting the setting would otherwise re-import forever.
  private static final int MAX_APPLIES = 3;

  @Override public Object execute(Project project, Continuation<? super Unit> continuation) {
    var repository = repositoryFor(project.getBasePath(), System.getProperty("agterm.rebased.mirrors"),
                                   System.getProperty("agterm.rebased.m2"));
    if (repository == null) return Unit.INSTANCE;
    var manager = MavenProjectsManager.getInstance(project);
    var applies = new AtomicInteger();
    // The first open of a Maven project links it after this activity and swaps in a fresh settings object
    // (MavenProjectAsyncBuilder.updateMavenSettingsFromEnvironment), so the setting is re-applied after each import.
    Runnable apply = () -> {
      var settings = manager.getGeneralSettings();
      if (repository.equals(settings.getLocalRepository())) return;
      if (applies.incrementAndGet() > MAX_APPLIES) {
        Bridge.log("maven local repository for " + project.getBasePath() + " keeps changing; left as " + settings.getLocalRepository());
        return;
      }
      // the override field, so it wins over a <localRepository> in ~/.m2/settings.xml
      settings.setLocalRepository(repository);
      Bridge.log("maven local repository " + repository + " for " + project.getBasePath());
      // an import that already ran used the old repository
      if (manager.isMavenizedProject()) manager.forceUpdateAllProjectsOrFindAllAvailablePomFiles();
    };
    manager.addManagerListener(new MavenProjectsManager.Listener() {
      @Override public void activated() { apply.run(); }
      @Override public void projectImportCompleted() { apply.run(); }
    }, Disposer.newDisposable(project, "agterm mirror maven"));
    apply.run();
    return Unit.INSTANCE;
  }

  /**
   * `<m2>/<host>/repository` for a project under `<mirrors>/<host>/`, once `<m2>/<host>` exists; the options name
   * real paths. Only a synced refresh creates that folder, so without mutagen the project keeps its own repository.
   * Not `repository` itself: mutagen makes it only when the first copy lands, after the project has opened.
   */
  static String repositoryFor(String basePath, String mirrors, String m2) {
    if (basePath == null || mirrors == null || m2 == null) return null;
    Path project;
    try {
      project = Path.of(basePath).toRealPath();
    } catch (Exception e) {
      project = Path.of(basePath).toAbsolutePath().normalize();
    }
    var root = Path.of(mirrors);
    if (!project.startsWith(root) || project.getNameCount() <= root.getNameCount()) return null;
    var repository = Path.of(m2, project.getName(root.getNameCount()).toString(), "repository");
    return Files.isDirectory(repository.getParent()) ? repository.toString() : null;
  }
}
