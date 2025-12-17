Pod::Spec.new do |s|
  s.name             = 'ffmpeg_remux'
  s.version          = '0.0.1'
  s.summary          = 'ffmpeg remux'
  s.description      = 'ffmpeg remux'
  s.homepage         = 'https://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'you' => 'you@example.com' }
  s.source           = { :path => '.' }

  s.platform = :ios, '12.0'
  s.swift_version = '5.0'

  # ✅ 你的源码（Swift + C）
  s.source_files = 'Classes/**/*.{swift,h,m,mm,c,cpp}'
  s.dependency 'Flutter'

  # ✅ 关键：把 xcframework 引进来（注意路径）
  s.vendored_frameworks = [
    'FFmpegMinXC/libavcodec.xcframework',
    'FFmpegMinXC/libavformat.xcframework',
    'FFmpegMinXC/libavutil.xcframework'
  ]

  # ✅ 关键：让编译器能找到 FFmpeg 头文件（从 xcframework 里出）
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES'
  }

  s.libraries = 'c++', 'z', 'iconv'
end