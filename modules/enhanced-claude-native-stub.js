// Enhanced Linux stub for claude-native module
// Key difference from existing solutions: Uses Electron APIs instead of no-ops
const { BrowserWindow, Notification, app, nativeImage } = require('electron');
const os = require('os');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');

// --- Safe-fs containment helpers (see openRootDir & friends below) ---

function fsError(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}

// Reject anything that could walk out of the root before touching the filesystem.
function checkSegments(segments) {
  if (!Array.isArray(segments) || segments.length === 0) {
    throw fsError('EINVAL', 'safe-fs: expected a non-empty array of path segments');
  }
  for (const seg of segments) {
    if (typeof seg !== 'string' || seg === '' || seg === '.' || seg === '..' ||
        seg.includes('/') || seg.includes('\\') || seg.includes('\0')) {
      throw fsError('EINVAL', `safe-fs: unsafe path segment ${JSON.stringify(seg)}`);
    }
  }
}

// The native module resolves these with openat2(RESOLVE_BENEATH), which JS cannot
// reach. Emulate its guarantee: realpath the deepest existing ancestor and require
// it to stay under the root, so a symlink aimed outside fails with ELOOP — the code
// the callers already treat as an unsafe path.
async function resolveBeneath(root, segments) {
  const base = root && root.path;
  if (typeof base !== 'string') throw fsError('EINVAL', 'safe-fs: invalid root handle');
  checkSegments(segments);

  const full = path.join(base, ...segments);
  let probe = full;
  for (;;) {
    let real;
    try {
      real = await fsp.realpath(probe);
    } catch (err) {
      // Not created yet — the containment check applies to its nearest existing parent.
      if (err.code === 'ENOENT' && path.dirname(probe) !== probe) {
        probe = path.dirname(probe);
        continue;
      }
      throw err;
    }
    if (real !== base && !real.startsWith(base + path.sep)) {
      throw fsError('ELOOP', `safe-fs: ${full} escapes root ${base}`);
    }
    return full;
  }
}

// Set Claude icon on every BrowserWindow so the dock shows the correct icon
if (process.platform === 'linux') {
  app.on('browser-window-created', (event, window) => {
    try {
      const iconPath = require('path').join(
        require('path').dirname(app.getAppPath()),
        'resources', 'icon.png'
      );
      const icon = nativeImage.createFromPath(iconPath);
      if (!icon.isEmpty()) window.setIcon(icon);
    } catch (e) {}
  });
}

class ClaudeNativeLinux {
  constructor() {
    this._mainWindow = null;
  }

  // Called by main process to register window
  setMainWindow(win) {
    this._mainWindow = win;
  }

  // OS version detection
  getWindowsVersion() {
    // Compatibility stub for code that checks Windows version
    return "10.0.0";
  }

  getWindowsElevationType() {
    // Windows-only concept. "default" maps to can_elevate=false upstream.
    return "default";
  }

  getOSVersion() {
    return os.release();
  }

  getPlatform() {
    return 'linux';
  }

  // Window effects - compositor handles these on Linux
  setWindowEffect(effect) {
    // macOS has vibrancy effects, Linux compositors handle this
    return true;
  }

  removeWindowEffect() {
    return true;
  }

  // CRITICAL: Window state - use Electron API, not hardcoded values
  getIsMaximized() {
    if (!this._mainWindow) return false;
    return this._mainWindow.isMaximized();
  }

  isFullScreen() {
    if (!this._mainWindow) return false;
    return this._mainWindow.isFullScreen();
  }

  // Called unguarded (no optional-chaining on the method) in the stealth-relaunch
  // path: `(r==null?void 0:r.isOtherAppFullscreen())??!1`. No Linux equivalent of
  // "is another app fullscreen", so report false.
  isOtherAppFullscreen() {
    return false;
  }

  isMinimized() {
    if (!this._mainWindow) return false;
    return this._mainWindow.isMinimized();
  }

  isVisible() {
    if (!this._mainWindow) return true;
    return this._mainWindow.isVisible();
  }

  // Window management
  maximize() {
    if (this._mainWindow) this._mainWindow.maximize();
  }

  minimize() {
    if (this._mainWindow) this._mainWindow.minimize();
  }

  restore() {
    if (this._mainWindow) this._mainWindow.restore();
  }

  focus() {
    if (this._mainWindow) this._mainWindow.focus();
  }

  show() {
    if (this._mainWindow) this._mainWindow.show();
  }

  hide() {
    if (this._mainWindow) this._mainWindow.hide();
  }

  close() {
    if (this._mainWindow) this._mainWindow.close();
  }

  // Notifications - delegate to Electron
  showNotification(options) {
    if (Notification.isSupported()) {
      const notification = new Notification(options);
      notification.show();
      return notification;
    }
    return null;
  }

  // Taskbar/dock integration
  flashFrame(flag) {
    if (this._mainWindow) {
      this._mainWindow.flashFrame(flag !== false);
    }
  }

  clearFlashFrame() {
    if (this._mainWindow) {
      this._mainWindow.flashFrame(false);
    }
  }

  setProgressBar(progress) {
    if (this._mainWindow) {
      // Clamp between 0 and 1
      const normalized = Math.max(0, Math.min(1, progress));
      this._mainWindow.setProgressBar(normalized);
    }
  }

  clearProgressBar() {
    if (this._mainWindow) {
      this._mainWindow.setProgressBar(-1);
    }
  }

  // Badge/overlay icon - limited support on Linux
  setOverlayIcon(icon, description) {
    // Not well supported on Linux, but try anyway
    if (this._mainWindow && this._mainWindow.setOverlayIcon) {
      this._mainWindow.setOverlayIcon(icon, description);
      return true;
    }
    return false;
  }

  clearOverlayIcon() {
    if (this._mainWindow && this._mainWindow.setOverlayIcon) {
      this._mainWindow.setOverlayIcon(null, '');
      return true;
    }
    return false;
  }

  setBadgeCount(count) {
    if (app && app.setBadgeCount) {
      app.setBadgeCount(count);
      return true;
    }
    return false;
  }

  getBadgeCount() {
    if (app && app.getBadgeCount) {
      return app.getBadgeCount();
    }
    return 0;
  }

  // System integration
  setAppUserModelId(id) {
    if (app && app.setAppUserModelId) {
      app.setAppUserModelId(id);
    }
  }

  // Keyboard constants - preserve from original if app uses them
  get KeyboardKey() {
    return {
      // Common key codes - add more if needed
      VK_RETURN: 13,
      VK_ESCAPE: 27,
      VK_SPACE: 32,
      VK_LEFT: 37,
      VK_UP: 38,
      VK_RIGHT: 39,
      VK_DOWN: 40,
      VK_DELETE: 46,
    };
  }

  // Accessibility features
  isAccessibilityEnabled() {
    // Linux doesn't have the same accessibility query API
    return true;
  }

  // Power management
  getPowerState() {
    return {
      onBattery: false,
      charging: false,
      percent: 100
    };
  }

  // Screen capture/recording detection
  isScreenCaptureAllowed() {
    return true;
  }

  // Microphone/camera access
  isMicrophoneAccessAllowed() {
    return true;
  }

  isCameraAccessAllowed() {
    return true;
  }

  // Safe-fs containment API (required as of v1.20186.1)
  // The app routes contained file access — document baselines, scratch roots — through
  // these, and explicitly refuses to fall back to a path-based open when the native
  // module lacks them ("@ant/claude-native is required for safe-fs containment", CC-2885).
  // Without them the app throws UnsafeRootError at startup, so these must exist.
  // Roots are opaque to the caller and are never closed, so hold a path rather than an fd.
  async openRootDir(rootPath) {
    if (typeof rootPath !== 'string' || rootPath === '') {
      throw fsError('EINVAL', 'safe-fs: root path must be a non-empty string');
    }
    const real = await fsp.realpath(rootPath);
    if (!(await fsp.stat(real)).isDirectory()) {
      throw fsError('ENOTDIR', `safe-fs: ${rootPath} is not a directory`);
    }
    return { __safeFsRoot: true, path: real };
  }

  async openBeneath(root, segments, flags, mode) {
    const full = await resolveBeneath(root, segments);
    // fsPromises.open() hands back a FileHandle that closes its fd on GC; callers want
    // a raw descriptor they close themselves via fs.close(), so use the callback form.
    return await new Promise((resolve, reject) => {
      fs.open(full, flags, mode ?? 0o600, (err, fd) => (err ? reject(err) : resolve(fd)));
    });
  }

  async mkdirBeneath(root, segments, mode) {
    const full = await resolveBeneath(root, segments);
    // Non-recursive on purpose: the caller emulates recursion by walking each path
    // prefix in turn and relying on EEXIST for the levels that already exist.
    await fsp.mkdir(full, { mode: mode ?? 0o700 });
  }

  async renameBeneath(root, fromSegments, toSegments) {
    const from = await resolveBeneath(root, fromSegments);
    const to = await resolveBeneath(root, toSegments);
    await fsp.rename(from, to);
  }

  async unlinkBeneath(root, segments) {
    await fsp.unlink(await resolveBeneath(root, segments));
  }

  getAppInfoForFile(filePath) {
    // Linux has no direct equivalent to the native macOS/Windows file-owner lookup.
    return null;
  }

  // System theme detection
  getSystemTheme() {
    const nativeTheme = require('electron').nativeTheme;
    return nativeTheme.shouldUseDarkColors ? 'dark' : 'light';
  }

  onSystemThemeChanged(callback) {
    const nativeTheme = require('electron').nativeTheme;
    nativeTheme.on('updated', () => {
      callback(nativeTheme.shouldUseDarkColors ? 'dark' : 'light');
    });
  }
}

// AuthRequest stub - returns isAvailable()=false so the app falls back to
// system browser auth instead of macOS ASWebAuthenticationSession
class AuthRequest {
  static isAvailable() {
    return false;
  }
  start() {
    return Promise.reject(new Error('AuthRequest not available on Linux'));
  }
  cancel() {}
}

// Export singleton instance with AuthRequest as a static property
const instance = new ClaudeNativeLinux();
instance.AuthRequest = AuthRequest;
instance.getActiveWindowHandle = () => null;
module.exports = instance;
