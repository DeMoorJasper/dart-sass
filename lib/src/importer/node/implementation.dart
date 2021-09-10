// Copyright 2017 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:async';

import 'package:js/js.dart';
import 'package:path/path.dart' as p;

import '../../node/function.dart';
import '../../node/importer_result.dart';
import '../../node/utils.dart';
import '../../node/render_context.dart';

class ParsedImporterResult {
  final String uri;
  final String contents;
  final bool isIndentedSyntax;

  ParsedImporterResult(String uri, String contents, bool isIndentedSyntax)
      : uri = uri,
        contents = contents,
        isIndentedSyntax = isIndentedSyntax;

  static ParsedImporterResult? fromObject(Object value) {
    if (value is! NodeImporterResult) {
      return null;
    }

    var uri = p.toUri(value.file).toString();
    var contents = value.contents;
    var isIndentedSyntax = value.isIndentedSyntax ?? uri.endsWith("sass");
    return ParsedImporterResult(uri, contents, isIndentedSyntax);
  }
}

class NodeImporter {
  /// The options for the `this` context in which importer functions are
  /// invoked.
  ///
  /// This is typed as [Object] because the public interface of [NodeImporter]
  /// is shared with the VM, which can't handle JS interop types.
  final Object _options;

  /// The importer functions passed in by the user.
  final List<JSFunction> _importers;

  NodeImporter(this._options, Iterable<Object> importers)
      : _importers = List.unmodifiable(importers.cast());

  /// Loads the stylesheet at [url] from an importer or load path.
  ///
  /// The [previous] URL is the URL of the stylesheet in which the import
  /// appeared. Returns the contents of the stylesheet and the URL to use as
  /// [previous] for imports within the loaded stylesheet.
  ParsedImporterResult? load(String url, Uri? previous, bool forImport) {
    // The previous URL is always an absolute file path for filesystem imports.
    var previousString = _previousToString(previous);
    for (var importer in _importers) {
      var value =
          call2(importer, _renderContext(forImport), url, previousString);
      if (value != null) {
        return ParsedImporterResult.fromObject(value);
      }
    }

    throw "Can't find stylesheet to import.";
  }

  /// Asynchronously loads the stylesheet at [url] from an importer or load
  /// path.
  ///
  /// The [previous] URL is the URL of the stylesheet in which the import
  /// appeared. Returns the contents of the stylesheet and the URL to use as
  /// [previous] for imports within the loaded stylesheet.
  Future<ParsedImporterResult?> loadAsync(
      String url, Uri? previous, bool forImport) async {
    // The previous URL is always an absolute file path for filesystem imports.
    var previousString = _previousToString(previous);
    for (var importer in _importers) {
      var value =
          await _callImporterAsync(importer, url, previousString, forImport);
      if (value != null) {
        return ParsedImporterResult.fromObject(value);
      }
    }

    throw "Can't find stylesheet to import.";
  }

  /// Converts [previous] to a string to pass to the importer function.
  String _previousToString(Uri? previous) {
    if (previous == null) return 'stdin';
    if (previous.scheme == 'file') return p.fromUri(previous);
    return previous.toString();
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
