/// Outbound links the app opens in a browser.
///
/// These are **compile-time constants**, so every install carries the URLs it
/// was built with and old builds keep opening the old ones indefinitely. The
/// previous values pointed at `gchofficial.github.io/iptvs/`, from when the
/// panel was a GitHub Pages project page; that path now serves a redirect
/// (`redirect/`) which forwards to the panel preserving the rest of the path,
/// so those builds still reach the right page. See docs/cloud-sync.md
/// "Hosting" before changing any of them again.
class AppLinks {
  AppLinks._();

  /// The legal and support pages live on the **panel** origin, not the website:
  /// that is where the files are (`panel/public/`) and where the Play and
  /// Microsoft Store listings point.
  static const privacyPolicy = 'https://panel.iptvs.click/privacy';
  static const support = 'https://panel.iptvs.click/support';
  static const deleteCloudAccount = 'https://panel.iptvs.click/delete-account';

  /// The public website and knowledge base — installing, adding a source,
  /// pairing, profiles, the remote, and troubleshooting.
  static const website = 'https://iptvs.click';

  /// Public source repository — also the honest "report an issue" channel for
  /// an open-source app (no in-app feedback form or analytics).
  static const repository = 'https://github.com/GCHOfficial/iptvs';
}
