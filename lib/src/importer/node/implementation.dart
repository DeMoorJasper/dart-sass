// Copyright 2017 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:async';

import 'package:js/js.dart';
import 'package:path/path.dart' as p;
import 'package:tuple/tuple.dart';

import '../../io.dart';
import '../../node/function.dart';
import '../../node/importer_result.dart';
import '../../node/utils.dart';
import '../../node/render_context.dart';

/// An importer that encapsulates Node Sass's import logic.
///
/// This isn't a normal [Importer] because Node Sass's import behavior isn't
/// compatible with Dart Sass's. In particular:
///
/// * Rather than doing URL resolution for relative imports, the importer is
///   passed the URL of the file that contains the import which it can then use
///   to do its own relative resolution. It's passed this even if that file was
///   imported by a different importer.
///
/// * Importers can return file paths rather than the contents of the imported
///   file. These paths are made absolute before they're passed as the previous
///   "URL" to other importers.
///
/// * The working directory is always implicitly an include path.
///
/// * The order of import precedence is as follows:
///
///   1. Filesystem imports relative to the base file.
///   2. Custom importer imports.
///   3. Filesystem imports relative to the working directory.
///   4. Filesystem imports relative to an `includePaths` path.
///   5. Filesystem imports relative to a `SASS_PATH` path.
class NodeImporter {
  /// The options for the `this` context in which importer functions are
  /// invoked.
  ///
  /// This is typed as [Object] because the public interface of [NodeImporter]
  /// is shared with the VM, which can't handle JS interop types.
  final Object _options;

  /// The include paths passed in by the user.
  final List<String> _includePaths;

  /// The importer functions passed in by the user.
  final List<JSFunction> _importers;

  NodeImporter(
      this._options, Iterable<String> includePaths, Iterable<Object> importers)
      : _includePaths = List.unmodifiable(_addSassPath(includePaths)),
        _importers = List.unmodifiable(importers.cast());

  /// Returns [includePaths] followed by any paths loaded from the `SASS_PATH`
  /// environment variable.
  static Iterable<String> _addSassPath(Iterable<String> includePaths) sync* {
    yield* includePaths;
    var sassPath = getEnvironmentVariable("SASS_PATH");
    if (sassPath == null) return;
    yield* sassPath.split(isWindows ? ';' : ':');
  }

  /// Loads the stylesheet at [url] from an importer or load path.
  ///
  /// The [previous] URL is the URL of the stylesheet in which the import
  /// appeared. Returns the contents of the stylesheet and the URL to use as
  /// [previous] for imports within the loaded stylesheet.
  NodeImporterResult? load(String url, Uri? previous, bool forImport) {
    // The previous URL is always an absolute file path for filesystem imports.
    var previousString = _previousToString(previous);
    for (var importer in _importers) {
      var value =
          call2(importer, _renderContext(forImport), url, previousString);
      if (value != null) {
        return _handleImportResult(url, previous, value, forImport);
      }
    }
  }

  /// Asynchronously loads the stylesheet at [url] from an importer or load
  /// path.
  ///
  /// The [previous] URL is the URL of the stylesheet in which the import
  /// appeared. Returns the contents of the stylesheet and the URL to use as
  /// [previous] for imports within the loaded stylesheet.
  Future<NodeImporterResult?> loadAsync(
      String url, Uri? previous, bool forImport) async {
    // The previous URL is always an absolute file path for filesystem imports.
    var previousString = _previousToString(previous);
    for (var importer in _importers) {
      var value =
          await _callImporterAsync(importer, url, previousString, forImport);
      if (value != null) {
        return _handleImportResult(url, previous, value, forImport);
      }
    }
  }

  /// Converts [previous] to a string to pass to the importer function.
  String _previousToString(Uri? previous) {
    if (previous == null) return 'stdin';
    if (previous.scheme == 'file') return p.fromUri(previous);
    return previous.toString();
  }

  /// Converts an importer's return [value] to a tuple that can be returned by
  /// [load].
  NodeImporterResult? _handleImportResult(
      String url, Uri? previous, Object value, bool forImport) {
    if (isJSError(value)) throw value;
    if (value is! NodeImporterResult) return null;

    return value;
  }

  /// Calls an importer that may or may not be asynchronous.
  Future<Object?> _callImporterAsync(JSFunction importer, String url,
      String previousString, bool forImport) async {
    var completer = Completer<Object>();

    var result = call3(importer, _renderContext(forImport), url, previousString,
        allowInterop(completer.complete));
    if (isUndefined(result)) return await completer.future;
    return result;
  }

  /// Returns the [RenderContext] in which to invoke importers.
  RenderContext _renderContext(bool fromImport) {
    var context = RenderContext(
        options: _options as RenderContextOptions, fromImport: fromImport);
    context.options.context = context;
    return context;
  }
}
