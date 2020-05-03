import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' show dirname, join, relative;
import 'package:yaml/yaml.dart';
import 'package:yamlicious/yamlicious.dart';

import 'logger.dart';
import 'package.dart';

enum IDE { AndroidStudio, IntelliJ }

String getAndroidSdkRoot() {
  String possibleSdkRoot = Platform.environment["ANDROID_SDK_ROOT"];
  if (possibleSdkRoot == null) {
    logger.stderr(
        "Android SDK root could not be found, ensure you've set the ANDROID_SDK_ROOT environment variable.");
    return "";
  }
  return possibleSdkRoot;
}

String getFlutterSdkRoot() {
  ProcessResult result = Process.runSync("which", ["flutter"]);
  String possiblePath = result.stdout.toString();
  if (!possiblePath.contains("bin/flutter")) {
    logger.stderr("Flutter SDK could not be found.");
    exit(1);
  }
  return File(result.stdout).parent.parent.path;
}

Future<void> launchIde(String workspacePath, IDE ide) async {
  String ideBundleId = "";

  switch (ide) {
    case IDE.AndroidStudio:
      ideBundleId = "com.google.android.studio";
      break;
    case IDE.IntelliJ:
      ideBundleId = "com.jetbrains.intellij";
      break;
  }

  await Process.start("open", ["-b", ideBundleId, "."],
      workingDirectory: workspacePath);
}

Map loadYamlFileSync(String path) {
  File file = new File(path);
  if (file?.existsSync() == true) {
    return loadYaml(file.readAsStringSync());
  }
  return null;
}

Future<Map> loadYamlFile(String path) async {
  File file = new File(path);
  if (await file?.exists() == true) {
    return loadYaml(await file.readAsString());
  }
  return null;
}

Directory getToolsDirectory() {
  return Directory(dirname(Platform.script.path)).parent;
}

Directory getWorkspacesDirectory() {
  return Directory(
      getToolsDirectory().path + Platform.pathSeparator + 'workspaces');
}

Future<void> linkPluginDependencies(Directory workspaceDirectory,
    MelosPackage plugin, List<MelosPackage> pluginsToLink) async {
  // .flutter-plugins
  File flutterPluginsFile =
      File(plugin.path + Platform.pathSeparator + '.flutter-plugins');

  if (await flutterPluginsFile.exists()) {
    String flutterPluginsContent = await flutterPluginsFile.readAsString();
    pluginsToLink.forEach((pluginToLink) {
      RegExp regex = RegExp("^${pluginToLink.name}=.*\$", multiLine: true);
      flutterPluginsContent = flutterPluginsContent.replaceAll(
          regex, "${pluginToLink.name}=${pluginToLink.path}");
    });

    await flutterPluginsFile.writeAsString(flutterPluginsContent);
  }

  // .packages
  File packagesFile = File(plugin.path + Platform.pathSeparator + '.packages');

  if (await packagesFile.exists()) {
    String packagesContents = await packagesFile.readAsString();
    pluginsToLink.forEach((pluginToLink) {
      RegExp regex = RegExp("^${pluginToLink.name}:.*\$", multiLine: true);
      packagesContents = packagesContents.replaceAll(
          regex, "${pluginToLink.name}:file://${pluginToLink.path}/lib/");
    });

    await packagesFile.writeAsString(packagesContents);
  }

  // .pubspec.lock
  File pubspecLockFile =
      File(plugin.path + Platform.pathSeparator + 'pubspec.lock');
  if (await pubspecLockFile.exists()) {
    Map workspacePubspecLock = loadYamlFileSync(
        File(workspaceDirectory.path + Platform.pathSeparator + 'pubspec.lock')
            .path);
    Map pubspecLock =
        json.decode(json.encode(loadYamlFileSync(pubspecLockFile.path)));

    pluginsToLink.forEach((pluginToLink) {
      if (pubspecLock['packages'][pluginToLink.name] != null) {
        Map pluginPackage = json.decode(
            json.encode(workspacePubspecLock['packages'][pluginToLink.name]));
        pluginPackage['description']['path'] =
            relativePath(pluginToLink.path, plugin.path);
        pubspecLock['packages'][pluginToLink.name] = pluginPackage;
      }
    });
    await pubspecLockFile.writeAsString(toYamlString(pubspecLock));
  }

  // .dart_tool/package_config.json
  File packageConfigFile = File(plugin.path +
      Platform.pathSeparator +
      '.dart_tool' +
      Platform.pathSeparator +
      'package_config.json');

  if (await packageConfigFile.exists()) {
    Map packageConfig = json.decode(await packageConfigFile.readAsString());
    if (packageConfig['packages'] != null) {
      pluginsToLink.forEach((pluginToLink) {
        var packages = packageConfig['packages'];
        List newPackages = List();
        packages.forEach((package) {
          if (package['name'] == pluginToLink.name) {
            package['rootUri'] = "file://${pluginToLink.path}";
            // TODO relative path
            // package['rootUri'] = relativePath(pluginToLink.path, plugin.path);
          }
          newPackages.add(package);
        });
        packageConfig['packages'] = newPackages;
      });

      JsonEncoder encoder = new JsonEncoder.withIndent("  ");
      await packageConfigFile.writeAsString(encoder.convert(packageConfig));
    }
  }
}

Directory getTemplateDirectory(String templateName) {
  return Directory(getToolsDirectory().path +
      Platform.pathSeparator +
      'templates' +
      Platform.pathSeparator +
      templateName);
}

Directory getTemplatesDirectory() {
  return Directory(
      getToolsDirectory().path + Platform.pathSeparator + 'templates');
}

Directory getWorkspaceDirectoryForProjectDirectory(Directory projectDirectory) {
  return Directory(getWorkspacesDirectory().path +
      Platform.pathSeparator +
      projectDirectory.path.hashCode.toString());
}

String melosYamlPathForDirectory(Directory pluginDirectory) {
  return pluginDirectory.path + Platform.pathSeparator + 'melos.yaml';
}

String pubspecPathForDirectory(Directory pluginDirectory) {
  return pluginDirectory.path + Platform.pathSeparator + 'pubspec.yaml';
}

String relativePath(String path, String from) {
  return relative(path, from: from);
}

void templateCopyTo(
    String templateName, Directory destination, Map<String, String> variables) {
  Directory templateDirectory = getTemplateDirectory(templateName);
  templateDirectory
      .listSync(recursive: true)
      .forEach((FileSystemEntity entity) {
    String filePath = entity.path.replaceAll(templateDirectory.path, ".");
    String destinationPath = join(destination.path, filePath);

    if (FileSystemEntity.isDirectorySync(entity.path)) {
      Directory(destinationPath).createSync(recursive: true);
      return;
    }

    String fileContents = File(entity.path).readAsStringSync();
    variables.forEach((key, value) {
      String replacePattern = "__${key}__";
      destinationPath = destinationPath.replaceAll(replacePattern, value);
      fileContents = fileContents.replaceAll(replacePattern, value);
    });

    File(destinationPath).writeAsStringSync(fileContents);
  });
}

/// Simple check to see if the [Directory] qualifies as a plugin repository.
bool isWorkspaceDirectory(Directory directory) {
  String melosYamlPath = melosYamlPathForDirectory(directory);
  return FileSystemEntity.isFileSync(melosYamlPath);
}

bool isPackageDirectory(Directory directory) {
  String pluginYamlPath = pubspecPathForDirectory(directory);
  return FileSystemEntity.isFileSync(pluginYamlPath);
}
