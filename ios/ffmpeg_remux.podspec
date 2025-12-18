Pod::Spec.new do |s|
  s.name             = 'ffmpeg_remux'
  s.version          = '0.0.1'
  s.summary          = 'Minimal FFmpeg remux (HLS m3u8 -> mp4)'
  s.description      = 'Minimal FFmpeg remux (HLS m3u8 -> mp4) for Flutter.'
  s.homepage         = 'https://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'you' => 'you@example.com' }
  s.source           = { :path => '.' }

  s.platform     = :ios, '12.0'
  s.swift_version = '5.0'
  s.static_framework = true

  # Flutter plugin iOS 必须
  s.dependency 'Flutter'

  # 你的 Swift / ObjC 源码
  s.source_files = 'Classes/**/*.{h,m,mm,swift}'
  s.public_header_files = 'Classes/**/*.h'

  # ✅ 关键：直接 vendored xcframework（不要再把 include/lib 当 source_files）
  s.vendored_frameworks = [
    'FFmpegMinXC/libavcodec.xcframework',
    'FFmpegMinXC/libavformat.xcframework',
    'FFmpegMinXC/libavutil.xcframework'
  ]

  # 需要的系统库（你之前遇到 iconv / uncompress 这种 undefined symbol 就靠这里）
  s.libraries = 'z', 'iconv', 'bz2'
  s.frameworks = 'Foundation'

  # 如果你 C 里用到了 crypto protocol，一般不需要额外系统库；FFmpeg 内部已静态
  # 但如果你还链接到了别的东西，再补

  # 编译参数（可选：压掉一些 warning）
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER' => 'NO',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited)'
  }
end