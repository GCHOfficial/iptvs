#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint iptvs_ios_player.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'iptvs_ios_player'
  s.version          = '0.0.1'
  s.summary          = 'iptvs native iOS player engine shim (AVPlayer + libmpv fallback).'
  s.description      = <<-DESC
Local-only Flutter plugin packaging iptvs's native iOS player. Step 1 ships
only the method-channel skeleton and a Foundation-only Core package of pure
playback-policy logic (Back-ladder, reconnect timing, colorimetry labels,
engine selection, badge formatting) mirrored from the Android Kotlin/Dart
implementations. See docs/ios.md.
                       DESC
  s.homepage         = 'https://github.com/GCHOfficial/iptvs'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'GCHOfficial' => 'gchofficial@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift', 'Core/Sources/**/*.swift'
  s.dependency 'Flutter'
  # Explicit rather than relying on Swift autolinking: AVKit (PiP) and
  # MediaPlayer (Now Playing / remote commands) are only reached through
  # Swift, and an autolink miss surfaces as an opaque link failure on a CI
  # runner rather than anywhere reproducible locally.
  s.frameworks = 'AVFoundation', 'AVKit', 'MediaPlayer'
  s.platform = :ios, '15.0'
  s.static_framework = true
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
