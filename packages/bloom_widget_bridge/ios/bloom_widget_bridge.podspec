Pod::Spec.new do |s|
  s.name             = 'bloom_widget_bridge'
  s.version          = '0.0.1'
  s.summary          = 'Bloom widget cache bridge.'
  s.description      = <<-DESC
Native cache and WidgetKit refresh bridge for Bloom.
                       DESC
  s.homepage         = 'https://bloom.jihu.top'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Bloom' => 'dev@bloom.local' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.swift_version = '5.0'
end
