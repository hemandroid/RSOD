/// Identity of the running build.
///
/// [commitSha] is the load-bearing field: the backend uses it to find the
/// symbols file that turns a release stack trace back into file and line
/// numbers. Set via `--dart-define=COMMIT_SHA=$(git rev-parse HEAD)` at
/// build time, alongside `--split-debug-info`.
class BuildIdentity {
  static const commitSha =
      String.fromEnvironment('COMMIT_SHA', defaultValue: 'unknown');
  static const appVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');

  /// True when the build was produced without a commit SHA, which means any
  /// crash it reports will arrive unsymbolicatable. Surfaced loudly at init
  /// rather than discovered later via an unreadable ticket.
  static bool get isUnidentified => commitSha == 'unknown';
}
