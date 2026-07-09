import Foundation
import OSLog
import PythonKit
import PythonSupport

/// Glue that wires `JavaScriptCore` into the embedded yt-dlp Python runtime so YouTube's
/// N/SIG challenges (the obfuscated functions in player.js that protect stream URLs) get
/// solved transparently — same as a desktop install with `deno` available, just running
/// on JavaScriptCore instead of V8.
///
/// **Four pieces, all installed by `install()`:**
/// 1. `builtins.eval_js(code) -> str` — Python-callable hook that runs JS via
///    `JSEvaluator`, wrapping the source so `console.log` output is captured and returned.
/// 2. **`yt_dlp_ejs` package shim** — three synthetic modules in `sys.modules`
///    (`yt_dlp_ejs`, `yt_dlp_ejs.yt`, `yt_dlp_ejs.yt.solver`) that expose `version`,
///    `core()`, `lib()` reading from the bundled `core.min.js` / `lib.min.js`. yt-dlp's
///    `_pypackage_source` finds this via `from yt_dlp.dependencies import yt_dlp_ejs` and
///    uses the JS content as its challenge-solver script source.
/// 3. **`DenoJsRuntime._info` stub** — replaces the real binary-probe with a function that
///    returns `JsRuntimeInfo(name='deno', path=..., version='2.0.0', version_tuple=(2,0,0),
///    supported=True)`. Without this, yt-dlp's `_js_runtimes['deno'].info` would be `None`
///    (no deno binary on iOS) and the whole EJS path gets skipped.
/// 4. **`subprocess.Popen` extension** — the YoutubeDL-iOS package already replaced
///    `subprocess.Popen` with its ffmpeg-only `Pop` class. We monkey-patch `Pop.__init__`
///    and `Pop.communicate` to also recognize argv starting with our fake deno path
///    (`/dev/null/freetube-deno`), route stdin through `eval_js`, and return the JS result
///    on stdout. `yt_dlp.utils.Popen` inherits from `Pop`, so this propagates to yt-dlp's
///    EJS provider without it knowing anything has changed.
///
/// **Ordering matters.** `install()` must be called **after** `YtDlp()`'s init has run
/// (which triggers `injectFakePopen` in YoutubeDL-iOS) and **before** `ydl.download`
/// (which triggers JSC provider registration and the first call to `_js_runtimes`). The
/// `freetube_yt_dlp` function in `FreeTubeYtDlp.swift` enforces this ordering.
///
/// **What we don't do:** we don't intercept ffmpeg/ffprobe — those still flow through the
/// YoutubeDL-iOS `popenHandler` path (now reached via fall-through from our patched
/// `Pop.__init__`). And we don't intercept `node`/`bun`/`quickjs` — yt-dlp's preference
/// ranks `deno` highest at 1000 and uses it if available, so wiring just deno is enough.
@available(iOS 17.0, *)
nonisolated enum PythonJSBridge {
    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "JSBridge")

    /// The fake path we pass as `js_runtimes={'deno': {'path': ...}}` and recognize in our
    /// patched `Pop.__init__`. Doesn't have to be a real path — yt-dlp only uses it as the
    /// argv[0] of `Popen` calls, which our shim intercepts before any filesystem access.
    static let fakeDenoPath = "/dev/null/freetube-deno"

    /// Strong reference to the `eval_js` callable. PythonKit's `PythonFunction` wraps a
    /// heap-allocated bridge; we keep a Swift-side strong ref so the bridge isn't torn
    /// down while Python still holds the function as `builtins.eval_js`.
    private static var retainedEvalJS: PythonFunction?

    /// Installs all four pieces. Safe to call multiple times — each piece guards against
    /// double-install (re-binding `builtins.eval_js`, idempotent `sys.modules` writes,
    /// idempotent monkey-patches via a sentinel attribute).
    static func install() {
        installEvalJSBuiltin()
        installEJSPackageShim()
        installRuntimeStub()
        installPopenExtension()
        log.info("PythonJSBridge installed (eval_js + yt_dlp_ejs shim + deno stub + Popen ext)")
    }

    // MARK: - 1. eval_js builtin

    /// Installs `builtins.eval_js(code: str) -> str`.
    ///
    /// Wraps the caller's JS source in a prologue that captures `console.log` to an array
    /// and a trailing expression that joins the captures — this lets yt-dlp's solver code
    /// (which writes its JSON result via `console.log(JSON.stringify(...))`) work without
    /// modification. `JSContext` doesn't ship a `console` global, so the prologue defines
    /// one inside the evaluation scope.
    private static func installEvalJSBuiltin() {
        let evalJS = PythonFunction { (args: PythonObject) -> PythonConvertible in
            guard let code = String(args[0]) else {
                let builtins = Python.import("builtins")
                let err = builtins.TypeError("eval_js: first argument must be a string")
                throw PythonError.exception(err, traceback: nil)
            }

            let wrapped = wrapForStdoutCapture(code)
            do {
                let result = try JSEvaluator.evaluate(wrapped)
                return PythonObject(result)
            } catch {
                let builtins = Python.import("builtins")
                let err = builtins.RuntimeError("eval_js: \(String(describing: error))")
                throw PythonError.exception(err, traceback: nil)
            }
        }
        retainedEvalJS = evalJS

        let builtins = Python.import("builtins")
        builtins.eval_js = evalJS.pythonObject
    }

    /// Wraps yt-dlp's stdin-style JS payload in an IIFE that:
    ///   - defines a fake `console` that pushes log args to an array,
    ///   - executes the user code in the same scope (so top-level `var` declarations from
    ///     `lib.min.js` and `core.min.js` are visible to each other and to the trailing
    ///     `console.log` call yt-dlp appends),
    ///   - returns the joined captured output as the IIFE result.
    ///
    /// The trailing newline before `})()` matters: `core.min.js` ends without a trailing
    /// newline and yt-dlp's payload glues scripts with newlines, so we mirror that.
    private static func wrapForStdoutCapture(_ userCode: String) -> String {
        return """
        ;(function() {
            var __ftStdout = [];
            var console = {
                log: function() {
                    var parts = Array.prototype.map.call(arguments, function(a) { return String(a); });
                    __ftStdout.push(parts.join(' '));
                },
                error: function() {}, warn: function() {}, info: function() {}, debug: function() {}
            };
        \(userCode)
            return __ftStdout.join('\\n');
        })()
        """
    }

    // MARK: - 2. yt_dlp_ejs package shim

    /// Installs the three synthetic modules. Reads bundled JS once and binds it into the
    /// modules' `core()` / `lib()` closures. Errors loading from the bundle abort the
    /// install (with a log) — `_has_ejs` will then be falsy and yt-dlp will fall through
    /// to the (non-pypackage) sources, which we don't ship either, so the EJS path will be
    /// effectively disabled. That's the correct fail-safe behavior.
    private static func installEJSPackageShim() {
        let coreJS: String
        let libJS: String
        do {
            coreJS = try EJSResources.core()
            libJS = try EJSResources.lib()
        } catch {
            log.error("EJS resources not found — skipping yt_dlp_ejs shim: \(String(describing: error), privacy: .public)")
            return
        }

        // Park the JS bodies on `builtins` so the Python setup code can read them without
        // string-escaping issues across the Swift → runSimpleString boundary.
        let builtins = Python.import("builtins")
        builtins.__ft_ejs_core_js__ = PythonObject(coreJS)
        builtins.__ft_ejs_lib_js__ = PythonObject(libJS)
        builtins.__ft_ejs_version__ = PythonObject(EJSResources.version)

        runSimpleString(ejsPackageShimPython)
        log.info("yt_dlp_ejs shim installed (core=\(coreJS.count) bytes, lib=\(libJS.count) bytes, version=\(EJSResources.version, privacy: .public))")
    }

    /// Python that builds `yt_dlp_ejs`, `yt_dlp_ejs.yt`, and `yt_dlp_ejs.yt.solver` as
    /// `types.ModuleType` instances and registers them in `sys.modules`. Each module is
    /// also attached as an attribute of its parent so `yt_dlp_ejs.yt.solver` works as
    /// attribute access (which is what `from yt_dlp.dependencies import yt_dlp_ejs as
    /// _has_ejs` + later `yt_dlp_ejs.yt.solver.core()` relies on).
    ///
    /// The `core()` / `lib()` closures pull from the `__ft_ejs_*_js__` builtins set
    /// before this script runs; that lets us avoid embedding ~158 KB of JS inside a
    /// Python triple-quoted string.
    private static let ejsPackageShimPython = """
    import sys
    import types
    import builtins

    # Idempotency: if already installed, just refresh content (in case of version bump).
    _existing = sys.modules.get('yt_dlp_ejs')
    if _existing is None or not hasattr(_existing, '_freetube_shim'):
        _ejs = types.ModuleType('yt_dlp_ejs')
        _ejs.__path__ = []  # marks it as a package so submodule imports resolve
        _ejs._freetube_shim = True
        _ejs.version = builtins.__ft_ejs_version__
        _ejs.__version__ = builtins.__ft_ejs_version__

        _ejs_yt = types.ModuleType('yt_dlp_ejs.yt')
        _ejs_yt.__path__ = []
        _ejs.yt = _ejs_yt

        _ejs_solver = types.ModuleType('yt_dlp_ejs.yt.solver')

        def _core():
            return builtins.__ft_ejs_core_js__

        def _lib():
            return builtins.__ft_ejs_lib_js__

        _ejs_solver.core = _core
        _ejs_solver.lib = _lib
        _ejs_yt.solver = _ejs_solver

        sys.modules['yt_dlp_ejs'] = _ejs
        sys.modules['yt_dlp_ejs.yt'] = _ejs_yt
        sys.modules['yt_dlp_ejs.yt.solver'] = _ejs_solver

    # If yt_dlp.dependencies was imported BEFORE our shim landed, its `yt_dlp_ejs`
    # attribute was set to `None` by the `except ImportError: yt_dlp_ejs = None` path.
    # Rebind it so existing `from yt_dlp.dependencies import yt_dlp_ejs as _has_ejs`
    # readers see truthy on next attribute access. (For modules that already imported
    # via `from ... import yt_dlp_ejs`, the local name is frozen — but those modules
    # haven't been loaded yet at this point in our flow.)
    _yt_dlp_deps = sys.modules.get('yt_dlp.dependencies')
    if _yt_dlp_deps is not None:
        _yt_dlp_deps.yt_dlp_ejs = sys.modules['yt_dlp_ejs']
    """

    // MARK: - 3. DenoJsRuntime info stub

    /// Replaces `yt_dlp.utils._jsruntime.DenoJsRuntime._info` with a function that returns
    /// a synthetic supported `JsRuntimeInfo`. Without this, yt-dlp's `_js_runtimes['deno']
    /// .info` would call the real `_info`, which spawns `deno --version` via
    /// `Popen.run(...)`. Our `Pop` patch handles that path too, but the cleaner contract
    /// is to short-circuit the probe — yt-dlp's other call sites for `runtime_info` (e.g.
    /// `is_available`) check the cached property, so a stub here covers them all.
    private static func installRuntimeStub() {
        runSimpleString(runtimeStubPython)
        log.info("DenoJsRuntime._info stub installed")
    }

    private static let runtimeStubPython = """
    try:
        from yt_dlp.utils._jsruntime import DenoJsRuntime, JsRuntimeInfo
        from yt_dlp.utils._jsruntime import _determine_runtime_path

        def _freetube_deno_info(self):
            path = _determine_runtime_path(self._path, 'deno')
            return JsRuntimeInfo(
                name='deno', path=path,
                version='2.0.0', version_tuple=(2, 0, 0),
                supported=True,
            )

        # Idempotency: only patch once.
        if not getattr(DenoJsRuntime, '_freetube_patched', False):
            DenoJsRuntime._info = _freetube_deno_info
            DenoJsRuntime._freetube_patched = True
    except Exception as _e:
        import sys
        print('PythonJSBridge: DenoJsRuntime patch failed:', _e, file=sys.stderr)
    """

    // MARK: - 4. Pop extension (subprocess.Popen monkey-patch)

    /// Extends the YoutubeDL-iOS `Pop` class (already installed as `subprocess.Popen` by
    /// `injectFakePopen`) to also handle the fake-deno argv path. `yt_dlp.utils.Popen` is
    /// a subclass of `Pop`, so `super().__init__` from yt-dlp's wrapper reaches our
    /// patched `__init__` and `super().communicate` reaches our patched `communicate`.
    ///
    /// **Why monkey-patch the class instead of replacing `subprocess.Popen`:** by the
    /// time we're called, `yt_dlp.utils` has already imported and frozen its `class
    /// Popen(subprocess.Popen):` with the *original* (pre-patch) `Pop` as its base.
    /// Rebinding `subprocess.Popen` to a new class wouldn't affect that MRO. Modifying
    /// the existing `Pop`'s methods does — Python looks up methods dynamically.
    private static func installPopenExtension() {
        let fakePathPyLiteral = "'\(fakeDenoPath)'"
        let py = popenExtensionPython.replacingOccurrences(of: "__FAKE_DENO_PATH__", with: fakePathPyLiteral)
        runSimpleString(py)
        log.info("Pop class extended with deno handler (path=\(fakeDenoPath, privacy: .public))")
    }

    private static let popenExtensionPython = """
    import subprocess
    import builtins

    _Pop = subprocess.Popen
    _FAKE_DENO_PATH = __FAKE_DENO_PATH__

    if not getattr(_Pop, '_freetube_patched', False):
        _orig_init = _Pop.__init__
        _orig_communicate = _Pop.communicate

        def _is_deno_argv(args):
            try:
                cmd = args[0]
            except Exception:
                return False
            if not isinstance(cmd, (list, tuple)) or len(cmd) == 0:
                return False
            return cmd[0] == _FAKE_DENO_PATH

        def _patched_init(self, *args, **kwargs):
            self._ft_deno = False
            if _is_deno_argv(args):
                self._ft_deno = True
                self._ft_cmd = args[0]
                self.returncode = None
                # yt_dlp.utils.Popen.__init__ sets self.__text_mode via name-mangling
                # (Popen__text_mode). We honor that via the text-mode kwargs the caller
                # passed: yt-dlp's deno provider passes text=True, so stdout/stderr we
                # return must be `str`. Track it so communicate returns the right type.
                self._ft_text_mode = bool(
                    kwargs.get('text')
                    or kwargs.get('universal_newlines')
                    or kwargs.get('encoding')
                    or kwargs.get('errors')
                )
                # Some yt-dlp code paths read .stdin/.stdout/.stderr on the proc object;
                # set placeholders so attribute access doesn't AttributeError.
                self.stdin = None
                self.stdout = None
                self.stderr = None
                return
            _orig_init(self, *args, **kwargs)

        def _patched_communicate(self, *args, **kwargs):
            if not getattr(self, '_ft_deno', False):
                return _orig_communicate(self, *args, **kwargs)

            # communicate(input=None, timeout=None) — yt-dlp passes the JS source
            # positionally as `input`.
            if args:
                stdin = args[0]
            else:
                stdin = kwargs.get('input', None)

            if stdin is None:
                stdin_str = ''
            elif isinstance(stdin, (bytes, bytearray)):
                stdin_str = stdin.decode('utf-8', errors='replace')
            else:
                stdin_str = str(stdin)

            text_mode = getattr(self, '_ft_text_mode', True)
            try:
                result = builtins.eval_js(stdin_str)
                self.returncode = 0
                if text_mode:
                    return (str(result), '')
                else:
                    return (str(result).encode('utf-8'), b'')
            except Exception as e:
                self.returncode = 1
                err_msg = f'freetube-jscore-shim: {e}'
                if text_mode:
                    return ('', err_msg)
                else:
                    return ('', err_msg.encode('utf-8'))

        def _patched_kill(self, *args, **kwargs):
            if getattr(self, '_ft_deno', False):
                return
            # Original Pop.kill takes no args; yt_dlp.utils.Popen.kill calls super().kill()
            # with no args. Pass through cleanly.
            try:
                return _orig_kill(self)
            except TypeError:
                return _orig_kill(self, *args, **kwargs)

        def _patched_wait(self, *args, **kwargs):
            if getattr(self, '_ft_deno', False):
                return self.returncode if self.returncode is not None else 0
            return _orig_wait(self, *args, **kwargs)

        _orig_kill = _Pop.kill
        _orig_wait = _Pop.wait

        _Pop.__init__ = _patched_init
        _Pop.communicate = _patched_communicate
        _Pop.kill = _patched_kill
        _Pop.wait = _patched_wait
        _Pop._freetube_patched = True
    """
}
