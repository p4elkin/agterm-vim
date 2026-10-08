package agterm.rebased;

import com.intellij.ide.AppLifecycleListener;
import com.intellij.openapi.application.ApplicationListener;
import com.intellij.openapi.application.ApplicationManager;
import java.util.concurrent.atomic.AtomicBoolean;

public final class Startup implements AppLifecycleListener {
  private static final AtomicBoolean installed = new AtomicBoolean();

  // A plugin.xml topic listener is not consulted by ApplicationImpl.canExit; only addApplicationListener is.
  private static void install(String from) {
    if (!installed.compareAndSet(false, true)) return;
    var app = ApplicationManager.getApplication();
    app.addApplicationListener(new ApplicationListener() {
      @Override public boolean canExitApplication() { Bridge.log("exit vetoed"); return false; }
      @Override public boolean canRestartApplication() { Bridge.log("restart vetoed"); return false; }
    }, app);
    // agterm opens the projects it wants; one reopened from the last run would sit hidden and cost memory
    com.intellij.ide.GeneralSettings.getInstance().setReopenLastProject(false);
    Bridge.install();
    Bridge.log("installed from " + from);
  }

  @Override public void appStarted() { install("appStarted"); }
  @Override public void welcomeScreenDisplayed() { install("welcomeScreenDisplayed"); }
}
