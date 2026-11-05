platform :ios, '15.0'

# 可选：接入后播放页会自动把 AVPlayer 解不了的容器（mkv/avi/rmvb/ts）切给 VLCKit
# 不装也能编译，只是这类片源会提示不支持
target 'TVBox' do
  use_frameworks! :linkage => :static

  pod 'MobileVLCKit', '~> 3.5'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      # VLCKit 没有 arm64 模拟器切片
      c.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'arm64'
    end
  end
end
