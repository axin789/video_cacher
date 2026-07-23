#
# video_cacher 的 iOS 侧：只桥接系统 CommonCrypto 做 AES-128-CBC 解密。
# 不包含任何 vendored framework / 预编译二进制。
#
Pod::Spec.new do |s|
  s.name             = 'video_cacher'
  s.version          = '0.3.0'
  s.summary          = 'System (hardware-accelerated) AES bridge for video_cacher.'
  s.description      = <<-DESC
Bridges HLS AES-128-CBC segment decryption to CommonCrypto so it runs on the
ARMv8 AES instructions. No bundled binaries, no vendored frameworks.
                       DESC
  s.homepage         = 'https://github.com/doubledog789/video_cacher'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'doubledog789' => '248255786+doubledog789@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
