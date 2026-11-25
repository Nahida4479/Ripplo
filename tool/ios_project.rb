require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'ios', 'Runner.xcodeproj'))
target = project.targets.find { |t| t.name == 'Runner' }
group = project.main_group['Runner']
abort 'Runner target or group not found' if target.nil? || group.nil?

compiled = target.source_build_phase.files.map { |f| f.file_ref && File.basename(f.file_ref.path.to_s) }.compact
Dir.glob(File.join(root, 'ios', 'Runner', '*.swift')).sort.each do |path|
  name = File.basename(path)
  next if compiled.include?(name)
  ref = group.files.find { |f| f.path == name } || group.new_file(name)
  target.add_file_references([ref])
end

entitlements = File.join(root, 'ios', 'Runner', 'Runner.entitlements')
if File.exist?(entitlements) && group.files.none? { |f| f.path == 'Runner.entitlements' }
  group.new_file('Runner.entitlements')
end

package_path = 'RipploSignal'
root_object = project.root_object
unless root_object.package_references.any? { |r| r.isa == 'XCLocalSwiftPackageReference' && r.relative_path == package_path }
  reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  reference.relative_path = package_path
  root_object.package_references << reference
end

unless target.package_product_dependencies.any? { |d| d.product_name == 'RipploSignal' }
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.product_name = 'RipploSignal'
  target.package_product_dependencies << dependency
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

target.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'io.github.nahida4479.ripplo'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  settings['SWIFT_VERSION'] = '5.0'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements' if File.exist?(entitlements)
end

project.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
end

project.save
