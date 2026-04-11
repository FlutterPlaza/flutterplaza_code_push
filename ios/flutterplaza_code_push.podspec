#
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutterplaza_code_push.podspec` to validate before pushing.
#
Pod::Spec.new do |s|
  s.name             = 'flutterplaza_code_push'
  s.version          = '0.1.6'
  s.summary          = 'Over-the-air code push updates for Flutter apps.'
  s.description      = <<-DESC
Over-the-air code push updates for Flutter apps. Check for updates,
download patches, and roll back — all at runtime.
                       DESC
  s.homepage         = 'https://codepush.flutterplaza.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'FlutterPlaza' => 'dev@flutterplaza.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
