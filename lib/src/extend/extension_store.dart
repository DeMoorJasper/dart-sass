// Copyright 2016 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:source_span/source_span.dart';
import 'package:tuple/tuple.dart';

import '../ast/css.dart';
import '../ast/css/modifiable.dart';
import '../ast/selector.dart';
import '../ast/sass.dart';
import '../exception.dart';
import '../utils.dart';
import '../util/nullable.dart';
import 'empty_extension_store.dart';
import 'extension.dart';
import 'merged_extension.dart';
import 'functions.dart';
import 'mode.dart';

/// Tracks selectors and extensions, and applies the latter to the former.
class ExtensionStore {
  /// An [ExtensionStore] that contains no extensions and can have no extensions added.
  static const empty = EmptyExtensionStore();

  /// A map from all simple selectors in the stylesheet to the selector lists
  /// that contain them.
  ///
  /// This is used to find which selectors an `@extend` applies to and adjust
  /// them.
  final Map<SimpleSelector, Set<ModifiableCssValue<SelectorList>>> _selectors;

  /// A map from all extended simple selectors to the sources of those
  /// extensions.
  final Map<SimpleSelector, Map<ComplexSelector, Extension>> _extensions;

  /// A map from all simple selectors in extenders to the extensions that those
  /// extenders define.
  final Map<SimpleSelector, List<Extension>> _extensionsByExtender;

  /// A map from CSS selectors to the media query contexts they're defined in.
  ///
  /// This tracks the contexts in which each selector's style rule is defined.
  /// If a rule is defined at the top level, it doesn't have an entry.
  final Map<ModifiableCssValue<SelectorList>, List<CssMediaQuery>>
      _mediaContexts;

  /// A map from [SimpleSelector]s to the specificity of their source
  /// selectors.
  ///
  /// This tracks the maximum specificity of the [ComplexSelector] that
  /// originally contained each [SimpleSelector]. This allows us to ensure that
  /// we don't trim any selectors that need to exist to satisfy the [second law
  /// of extend][].
  ///
  /// [second law of extend]: https://github.com/sass/sass/issues/324#issuecomment-4607184
  final Map<SimpleSelector, int> _sourceSpecificity;

  /// A set of [ComplexSelector]s that were originally part of
  /// their component [SelectorList]s, as opposed to being added by `@extend`.
  ///
  /// This allows us to ensure that we don't trim any selectors that need to
  /// exist to satisfy the [first law of extend][].
  ///
  /// [first law of extend]: https://github.com/sass/sass/issues/324#issuecomment-4607184
  final Set<ComplexSelector> _originals;

  /// The mode that controls this extender's behavior.
  final ExtendMode _mode;

  /// Whether this extender has no extensions.
  bool get isEmpty => _extensions.isEmpty;

  /// Extends [selector] with [source] extender and [targets] extendees.
  ///
  /// This works as though `source {@extend target}` were written in the
  /// stylesheet, with the exception that [target] can contain compound
  /// selectors which must be extended as a unit.
  static SelectorList extend(SelectorList selector, SelectorList source,
          SelectorList targets, FileSpan span) =>
      _extendOrReplace(selector, source, targets, ExtendMode.allTargets, span);

  /// Returns a copy of [selector] with [targets] replaced by [source].
  static SelectorList replace(SelectorList selector, SelectorList source,
          SelectorList targets, FileSpan span) =>
      _extendOrReplace(selector, source, targets, ExtendMode.replace, span);

  /// A helper function for [extend] and [replace].
  static SelectorList _extendOrReplace(
      SelectorList selector,
      SelectorList source,
      SelectorList targets,
      ExtendMode mode,
      FileSpan span) {
    var extender = ExtensionStore._mode(mode);
    if (!selector.isInvisible) {
      extender._originals.addAll(selector.components);
    }

    for (var complex in targets.components) {
      if (complex.components.length != 1) {
        throw SassScriptException("Can't extend complex selector $complex.");
      }
      var compound = complex.components.first as CompoundSelector;

      selector = extender._extendList(selector, span, {
        for (var simple in compound.components)
          simple: {
            for (var complex in source.components)
              complex: Extension(complex, span, simple, span, optional: true)
          }
      });
    }

    return selector;
  }

  /// The set of all simple selectors in selectors handled by this extender.
  ///
  /// This includes simple selectors that were added because of downstream
  /// extensions.
  Set<SimpleSelector> get simpleSelectors => MapKeySet(_selectors);

  ExtensionStore() : this._mode(ExtendMode.normal);

  ExtensionStore._mode(this._mode)
      : _selectors = {},
        _extensions = {},
        _extensionsByExtender = {},
        _mediaContexts = {},
        _sourceSpecificity = Map.identity(),
        _originals = Set.identity();

  ExtensionStore._(
      this._selectors,
      this._extensions,
      this._extensionsByExtender,
      this._mediaContexts,
      this._sourceSpecificity,
      this._originals)
      : _mode = ExtendMode.normal;

  /// Returns all mandatory extensions in this extender for whose targets
  /// [callback] returns `true`.
  ///
  /// This un-merges any [MergedExtension] so only base [Extension]s are
  /// returned.
  Iterable<Extension> extensionsWhereTarget(
      bool callback(SimpleSelector target)) sync* {
    for (var entry in _extensions.entries) {
      if (!callback(entry.key)) continue;
      for (var extension in entry.value.values) {
        if (extension is MergedExtension) {
          yield* extension
              .unmerge()
              .where((extension) => !extension.isOptional);
        } else if (!extension.isOptional) {
          yield extension;
        }
      }
    }
  }

  /// Adds [selector] to this extender.
  ///
  /// Extends [selector] using any registered extensions, then returns an empty
  /// [ModifiableCssValue] containing the resulting selector. If any more
  /// relevant extensions are added, the returned selector is automatically
  /// updated.
  ///
  /// The [mediaContext] is the media query context in which the selector was
  /// defined, or `null` if it was defined at the top level of the document.
  ModifiableCssValue<SelectorList> addSelector(
      SelectorList selector, FileSpan selectorSpan,
      [List<CssMediaQuery>? mediaContext]) {
    var originalSelector = selector;
    if (!originalSelector.isInvisible) {
      for (var complex in originalSelector.components) {
        _originals.add(complex);
      }
    }

    if (_extensions.isNotEmpty) {
      try {
        selector = _extendList(
            originalSelector, selectorSpan, _extensions, mediaContext);
      } on SassException catch (error) {
        throw SassException(
            "From ${error.span.message('')}\n"
            "${error.message}",
            error.span);
      }
    }

    var modifiableSelector = ModifiableCssValue(selector, selectorSpan);
    if (mediaContext != null) _mediaContexts[modifiableSelector] = mediaContext;
    _registerSelector(selector, modifiableSelector);

    return modifiableSelector;
  }

  /// Registers the [SimpleSelector]s in [list] to point to [selector] in
  /// [_selectors].
  void _registerSelector(
      SelectorList list, ModifiableCssValue<SelectorList> selector) {
    for (var complex in list.components) {
      for (var component in complex.components) {
        if (component is! CompoundSelector) continue;

        for (var simple in component.components) {
          _selectors.putIfAbsent(simple, () => {}).add(selector);
          if (simple is! PseudoSelector) continue;

          var selectorInPseudo = simple.selector;
          if (selectorInPseudo != null) {
            _registerSelector(selectorInPseudo, selector);
          }
        }
      }
    }
  }

  /// Adds an extension to this extender.
  ///
  /// The [extender] is the selector for the style rule in which the extension
  /// is defined, and [target] is the selector passed to `@extend`. The [extend]
  /// provides the extend span and indicates whether the extension is optional.
  ///
  /// The [mediaContext] defines the media query context in which the extension
  /// is defined. It can only extend selectors within the same context. A `null`
  /// context indicates no media queries.
  void addExtension(
      CssValue<SelectorList> extender, SimpleSelector target, ExtendRule extend,
      [List<CssMediaQuery>? mediaContext]) {
    var selectors = _selectors[target];
    var existingExtensions = _extensionsByExtender[target];

    Map<ComplexSelector, Extension>? newExtensions;
    var sources = _extensions.putIfAbsent(target, () => {});
    for (var complex in extender.value.components) {
      var extension = Extension(complex, extender.span, target, extend.span,
          mediaContext: mediaContext, optional: extend.isOptional);

      var existingExtension = sources[complex];
      if (existingExtension != null) {
        // If there's already an extend from [extender] to [target], we don't need
        // to re-run the extension. We may need to mark the extension as
        // mandatory, though.
        sources[complex] = MergedExtension.merge(existingExtension, extension);
        continue;
      }

      sources[complex] = extension;

      for (var simple in _simpleSelectors(complex)) {
        _extensionsByExtender.putIfAbsent(simple, () => []).add(extension);
        // Only source specificity for the original selector is relevant.
        // Selectors generated by `@extend` don't get new specificity.
        _sourceSpecificity.putIfAbsent(simple, () => complex.maxSpecificity);
      }

      if (selectors != null || existingExtensions != null) {
        newExtensions ??= {};
        newExtensions[complex] = extension;
      }
    }

    if (newExtensions == null) return;

    var newExtensionsByTarget = {target: newExtensions};
    if (existingExtensions != null) {
      var additionalExtensions =
          _extendExistingExtensions(existingExtensions, newExtensionsByTarget);
      if (additionalExtensions != null) {
        mapAddAll2(newExtensionsByTarget, additionalExtensions);
      }
    }

    if (selectors != null) {
      _extendExistingSelectors(selectors, newExtensionsByTarget);
    }
  }

  /// Returns an iterable of all simple selectors in [complex]
  Iterable<SimpleSelector> _simpleSelectors(ComplexSelector complex) sync* {
    for (var component in complex.components) {
      if (component is CompoundSelector) {
        for (var simple in component.components) {
          yield simple;

          if (simple is! PseudoSelector) continue;
          var selector = simple.selector;
          if (selector == null) continue;
          for (var complex in selector.components) {
            yield* _simpleSelectors(complex);
          }
        }
      }
    }
  }

  /// Extend [extensions] using [newExtensions].
  ///
  /// Note that this does duplicate some work done by
  /// [_extendExistingSelectors], but it's necessary to expand each extension's
  /// extender separately without reference to the full selector list, so that
  /// relevant results don't get trimmed too early.
  ///
  /// Returns extensions that should be added to [newExtensions] before
  /// extending selectors in order to properly handle extension loops such as:
  ///
  ///     .c {x: y; @extend .a}
  ///     .x.y.a {@extend .b}
  ///     .z.b {@extend .c}
  ///
  /// Returns `null` if there are no extensions to add.
  Map<SimpleSelector, Map<ComplexSelector, Extension>>?
      _extendExistingExtensions(List<Extension> extensions,
          Map<SimpleSelector, Map<ComplexSelector, Extension>> newExtensions) {
    Map<SimpleSelector, Map<ComplexSelector, Extension>>? additionalExtensions;

    for (var extension in extensions.toList()) {
      var sources = _extensions[extension.target]!;

      List<ComplexSelector>? selectors;
      try {
        selectors = _extendComplex(extension.extender.selector,
            extension.extender.span, newExtensions, extension.mediaContext);
        if (selectors == null) continue;
      } on SassException catch (error) {
        throw SassException(
            "From ${extension.extender.span.message('')}\n"
            "${error.message}",
            error.span);
      }

      var containsExtension = selectors.first == extension.extender.selector;
      var first = true;
      for (var complex in selectors) {
        // If the output contains the original complex selector, there's no
        // need to recreate it.
        if (containsExtension && first) {
          first = false;
          continue;
        }

        var withExtender = extension.withExtender(complex);
        var existingExtension = sources[complex];
        if (existingExtension != null) {
          sources[complex] =
              MergedExtension.merge(existingExtension, withExtender);
        } else {
          sources[complex] = withExtender;

          for (var component in complex.components) {
            if (component is CompoundSelector) {
              for (var simple in component.components) {
                _extensionsByExtender
                    .putIfAbsent(simple, () => [])
                    .add(withExtender);
              }
            }
          }

          if (newExtensions.containsKey(extension.target)) {
            additionalExtensions ??= {};
            var additionalSources =
                additionalExtensions.putIfAbsent(extension.target, () => {});
            additionalSources[complex] = withExtender;
          }
        }
      }

      // If [selectors] doesn't contain [extension.extender], for example if it
      // was replaced due to :not() expansion, we must get rid of the old
      // version.
      if (!containsExtension) sources.remove(extension.extender);
    }

    return additionalExtensions;
  }

  /// Extend [extensions] using [newExtensions].
  void _extendExistingSelectors(Set<ModifiableCssValue<SelectorList>> selectors,
      Map<SimpleSelector, Map<ComplexSelector, Extension>> newExtensions) {
    for (var selector in selectors) {
      var oldValue = selector.value;
      try {
        selector.value = _extendList(selector.value, selector.span,
            newExtensions, _mediaContexts[selector]);
      } on SassException catch (error) {
        // TODO(nweiz): Make this a MultiSpanSassException.
        throw SassException(
            "From ${selector.span.message('')}\n"
            "${error.message}",
            error.span);
      }

      // If no extends actually happened (for example because unification
      // failed), we don't need to re-register the selector.
      if (identical(oldValue, selector.value)) continue;
      _registerSelector(selector.value, selector);
    }
  }

  /// Extends [this] with all the extensions in [extensions].
  ///
  /// These extensions will extend all selectors already in [this], but they
  /// will *not* extend other extensions from [extensionStores].
  void addExtensions(Iterable<ExtensionStore> extensionStores) {
    // Extensions already in [this] whose extenders are extended by
    // [extensions], and thus which need to be updated.
    List<Extension>? extensionsToExtend;

    // Selectors that contain simple selectors that are extended by
    // [extensions], and thus which need to be extended themselves.
    Set<ModifiableCssValue<SelectorList>>? selectorsToExtend;

    // An extension map with the same structure as [_extensions] that only
    // includes extensions from [extensionStores].
    Map<SimpleSelector, Map<ComplexSelector, Extension>>? newExtensions;

    for (var extensionStore in extensionStores) {
      if (extensionStore.isEmpty) continue;
      _sourceSpecificity.addAll(extensionStore._sourceSpecificity);
      extensionStore._extensions.forEach((target, newSources) {
        // Private selectors can't be extended across module boundaries.
        if (target is PlaceholderSelector && target.isPrivate) return;

        // Find existing extensions to extend.
        var extensionsForTarget = _extensionsByExtender[target];
        if (extensionsForTarget != null) {
          (extensionsToExtend ??= []).addAll(extensionsForTarget);
        }

        // Find existing selectors to extend.
        var selectorsForTarget = _selectors[target];
        if (selectorsForTarget != null) {
          (selectorsToExtend ??= {}).addAll(selectorsForTarget);
        }

        // Add [newSources] to [_extensions].
        var existingSources = _extensions[target];
        if (existingSources == null) {
          _extensions[target] = Map.of(newSources);
          if (extensionsForTarget != null || selectorsForTarget != null) {
            (newExtensions ??= {})[target] = Map.of(newSources);
          }
        } else {
          newSources.forEach((extender, extension) {
            extension = existingSources.putOrMerge(
                extender, extension, MergedExtension.merge);

            if (extensionsForTarget != null || selectorsForTarget != null) {
              (newExtensions ??= {}).putIfAbsent(target, () => {})[extender] =
                  extension;
            }
          });
        }
      });
    }

    // We can't just naively check for `null` here due to dart-lang/sdk#45348.
    newExtensions.andThen((newExtensions) {
      // We can ignore the return value here because it's only useful for extend
      // loops, which can't exist across module boundaries.
      extensionsToExtend.andThen((extensionsToExtend) =>
          _extendExistingExtensions(extensionsToExtend, newExtensions));

      selectorsToExtend.andThen((selectorsToExtend) =>
          _extendExistingSelectors(selectorsToExtend, newExtensions));
    });
  }

  /// Extends [list] using [extensions].
  SelectorList _extendList(SelectorList list, FileSpan listSpan,
      Map<SimpleSelector, Map<ComplexSelector, Extension>> extensions,
      [List<CssMediaQuery>? mediaQueryContext]) {
    // This could be written more simply using [List.map], but we want to avoid
    // any allocations in the common case where no extends apply.
    List<ComplexSelector>? extended;
    for (var i = 0; i < list.components.length; i++) {
      var complex = list.components[i];
      var result =
          _extendComplex(complex, listSpan, extensions, mediaQueryContext);
      if (result == null) {
        if (extended != null) extended.add(complex);
      } else {
        extended ??= i == 0 ? [] : list.components.sublist(0, i).toList();
        extended.addAll(result);
      }
    }
    if (extended == null) return list;

    return SelectorList(_trim(extended, _originals.contains));
  }

  /// Extends [complex] using [extensions], and returns the contents of a
  /// [SelectorList].
  List<ComplexSelector>? _extendComplex(
      ComplexSelector complex,
      FileSpan complexSpan,
      Map<SimpleSelector, Map<ComplexSelector, Extension>> extensions,
      List<CssMediaQuery>? mediaQueryContext) {
    // The complex selectors that each compound selector in [complex.components]
    // can expand to.
    //
    // For example, given
    //
    //     .a .b {...}
    //     .x .y {@extend .b}
    //
    // this will contain
    //
    //     [
    //       [.a],
    //       [.b, .x .y]
    //     ]
    //
    // This could be written more simply using [List.map], but we want to avoid
    // any allocations in the common case where no extends apply.
    List<List<ComplexSelector>>? extendedNotExpanded;
    var isOriginal = _originals.contains(complex);
    for (var i = 0; i < complex.components.length; i++) {
      var component = complex.components[i];
      if (component is CompoundSelector) {
        var extended = _extendCompound(
            component, complexSpan, extensions, mediaQueryContext,
            inOriginal: isOriginal);
        if (extended == null) {
          extendedNotExpanded?.add([
            ComplexSelector([component])
          ]);
        } else {
          extendedNotExpanded ??= complex.components
              .take(i)
              .map((component) => [
                    ComplexSelector([component], lineBreak: complex.lineBreak)
                  ])
              .toList();
          extendedNotExpanded.add(extended);
        }
      } else {
        extendedNotExpanded?.add([
          ComplexSelector([component])
        ]);
      }
    }
    if (extendedNotExpanded == null) return null;

    var first = true;
    return paths(extendedNotExpanded).expand((path) {
      return weave(path.map((complex) => complex.components).toList())
          .map((components) {
        var outputComplex = ComplexSelector(components,
            lineBreak: complex.lineBreak ||
                path.any((inputComplex) => inputComplex.lineBreak));

        // Make sure that copies of [complex] retain their status as "original"
        // selectors. This includes selectors that are modified because a :not()
        // was extended into.
        if (first && _originals.contains(complex)) {
          _originals.add(outputComplex);
        }
        first = false;

        return outputComplex;
      });
    }).toList();
  }

  /// Extends [compound] using [extensions], and returns the contents of a
  /// [SelectorList].
  ///
  /// The [inOriginal] parameter indicates whether this is in an original
  /// complex selector, meaning that [compound] should not be trimmed out.
  List<ComplexSelector>? _extendCompound(
      CompoundSelector compound,
      FileSpan compoundSpan,
      Map<SimpleSelector, Map<ComplexSelector, Extension>> extensions,
      List<CssMediaQuery>? mediaQueryContext,
      {required bool inOriginal}) {
    // If there's more than one target and they all need to match, we track
    // which targets are actually extended.
    var targetsUsed = _mode == ExtendMode.normal || extensions.length < 2
        ? null
        : <SimpleSelector>{};

    // The complex selectors produced from each component of [compound].
    List<List<Extender>>? options;
    for (var i = 0; i < compound.components.length; i++) {
      var simple = compound.components[i];
      var extended = _extendSimple(
          simple, compoundSpan, extensions, mediaQueryContext, targetsUsed);
      if (extended == null) {
        options?.add([_extenderForSimple(simple, compoundSpan)]);
      } else {
        if (options == null) {
          options = [];
          if (i != 0) {
            options.add([
              _extenderForCompound(compound.components.take(i), compoundSpan)
            ]);
          }
        }

        options.addAll(extended);
      }
    }
    if (options == null) return null;

    // If [_mode] isn't [ExtendMode.normal] and we didn't use all the targets in
    // [extensions], extension fails for [compound].
    if (targetsUsed != null && targetsUsed.length != extensions.length) {
      return null;
    }

    // Optimize for the simple case of a single simple selector that doesn't
    // need any unification.
    if (options.length == 1) {
      return options.first.map((extender) {
        extender.assertCompatibleMediaContext(mediaQueryContext);
        return extender.selector;
      }).toList();
    }

    // Find all paths through [options]. In this case, each path represents a
    // different unification of the base selector. For example, if we have:
    //
    //     .a.b {...}
    //     .w .x {@extend .a}
    //     .y .z {@extend .b}
    //
    // then [options] is `[[.a, .w .x], [.b, .y .z]]` and `paths(options)` is
    //
    //     [
    //       [.a, .b],
    //       [.a, .y .z],
    //       [.w .x, .b],
    //       [.w .x, .y .z]
    //     ]
    //
    // We then unify each path to get a list of complex selectors:
    //
    //     [
    //       [.a.b],
    //       [.y .a.z],
    //       [.w .x.b],
    //       [.w .y .x.z, .y .w .x.z]
    //     ]
    //
    // And finally flatten them to get:
    //
    //     [
    //       .a.b,
    //       .y .a.z,
    //       .w .x.b,
    //       .w .y .x.z,
    //       .y .w .x.z
    //     ]
    var first = _mode != ExtendMode.replace;
    var result = paths(options)
        .map((path) {
          List<List<ComplexSelectorComponent>>? complexes;
          if (first) {
            // The first path is always the original selector. We can't just
            // return [compound] directly because pseudo selectors may be
            // modified, but we don't have to do any unification.
            first = false;
            complexes = [
              [
                CompoundSelector(path.expand((extender) {
                  assert(extender.selector.components.length == 1);
                  return (extender.selector.components.last as CompoundSelector)
                      .components;
                }))
              ]
            ];
          } else {
            var toUnify = QueueList<List<ComplexSelectorComponent>>();
            List<SimpleSelector>? originals;
            for (var extender in path) {
              if (extender.isOriginal) {
                originals ??= [];
                originals.addAll(
                    (extender.selector.components.last as CompoundSelector)
                        .components);
              } else {
                toUnify.add(extender.selector.components);
              }
            }

            if (originals != null) {
              toUnify.addFirst([CompoundSelector(originals)]);
            }

            complexes = unifyComplex(toUnify);
            if (complexes == null) return null;
          }

          var lineBreak = false;
          for (var extender in path) {
            extender.assertCompatibleMediaContext(mediaQueryContext);
            lineBreak = lineBreak || extender.selector.lineBreak;
          }

          return complexes
              .map((components) =>
                  ComplexSelector(components, lineBreak: lineBreak))
              .toList();
        })
        .whereNotNull()
        .expand((l) => l)
        .toList();

    // If we're preserving the original selector, mark the first unification as
    // such so [_trim] doesn't get rid of it.
    var isOriginal = (ComplexSelector _) => false;
    if (inOriginal && _mode != ExtendMode.replace) {
      var original = result.first;
      isOriginal = (complex) => complex == original;
    }

    return _trim(result, isOriginal);
  }

  Iterable<List<Extender>>? _extendSimple(
      SimpleSelector simple,
      FileSpan simpleSpan,
      Map<SimpleSelector, Map<ComplexSelector, Extension>> extensions,
      List<CssMediaQuery>? mediaQueryContext,
      Set<SimpleSelector>? targetsUsed) {
    // Extends [simple] without extending the contents of any selector pseudos
    // it contains.
    List<Extender>? withoutPseudo(SimpleSelector simple) {
      var extensionsForSimple = extensions[simple];
      if (extensionsForSimple == null) return null;
      targetsUsed?.add(simple);

      return [
        if (_mode != ExtendMode.replace) _extenderForSimple(simple, simpleSpan),
        for (var extension in extensionsForSimple.values) extension.extender
      ];
    }

    if (simple is PseudoSelector && simple.selector != null) {
      var extended =
          _extendPseudo(simple, simpleSpan, extensions, mediaQueryContext);
      if (extended != null) {
        return extended.map((pseudo) =>
            withoutPseudo(pseudo) ?? [_extenderForSimple(pseudo, simpleSpan)]);
      }
    }

    return withoutPseudo(simple).andThen((result) => [result]);
  }

  /// Returns an [Extender] composed solely of a compound selector containing
  /// [simples].
  Extender _extenderForCompound(
      Iterable<SimpleSelector> simples, FileSpan span) {
    var compound = CompoundSelector(simples);
    return Extender(ComplexSelector([compound]), span,
        specificity: _sourceSpecificityFor(compound), original: true);
  }

  /// Returns an [Extender] composed solely of [simple].
  Extender _extenderForSimple(SimpleSelector simple, FileSpan span) => Extender(
      ComplexSelector([
        CompoundSelector([simple])
      ]),
      span,
      specificity: _sourceSpecificity[simple] ?? 0,
      original: true);

  /// Extends [pseudo] using [extensions], and returns a list of resulting
  /// pseudo selectors.
  ///
  /// This requires that [pseudo] have a selector argument.
  List<PseudoSelector>? _extendPseudo(
      PseudoSelector pseudo,
      FileSpan pseudoSpan,
      Map<SimpleSelector, Map<ComplexSelector, Extension>> extensions,
      List<CssMediaQuery>? mediaQueryContext) {
    var selector = pseudo.selector;
    if (selector == null) {
      throw ArgumentError("Selector $pseudo must have a selector argument.");
    }

    var extended =
        _extendList(selector, pseudoSpan, extensions, mediaQueryContext);
    if (identical(extended, selector)) return null;

    // For `:not()`, we usually want to get rid of any complex selectors because
    // that will cause the selector to fail to parse on all browsers at time of
    // writing. We can keep them if either the original selector had a complex
    // selector, or the result of extending has only complex selectors, because
    // either way we aren't breaking anything that isn't already broken.
    Iterable<ComplexSelector> complexes = extended.components;
    if (pseudo.normalizedName == "not" &&
        !selector.components.any((complex) => complex.components.length > 1) &&
        extended.components.any((complex) => complex.components.length == 1)) {
      complexes = extended.components
          .where((complex) => complex.components.length <= 1);
    }

    complexes = complexes.expand((complex) {
      if (complex.components.length != 1) return [complex];
      if (complex.components.first is! CompoundSelector) return [complex];
      var compound = complex.components.first as CompoundSelector;
      if (compound.components.length != 1) return [complex];
      if (compound.components.first is! PseudoSelector) return [complex];
      var innerPseudo = compound.components.first as PseudoSelector;
      var innerSelector = innerPseudo.selector;
      if (innerSelector == null) return [complex];

      switch (pseudo.normalizedName) {
        case 'not':
          // In theory, if there's a `:not` nested within another `:not`, the
          // inner `:not`'s contents should be unified with the return value.
          // For example, if `:not(.foo)` extends `.bar`, `:not(.bar)` should
          // become `.foo:not(.bar)`. However, this is a narrow edge case and
          // supporting it properly would make this code and the code calling it
          // a lot more complicated, so it's not supported for now.
          if (innerPseudo.normalizedName != 'is' &&
              innerPseudo.normalizedName != 'matches') {
            return [];
          }
          return innerSelector.components;

        case 'is':
        case 'matches':
        case 'any':
        case 'current':
        case 'nth-child':
        case 'nth-last-child':
          // As above, we could theoretically support :not within :matches, but
          // doing so would require this method and its callers to handle much
          // more complex cases that likely aren't worth the pain.
          if (innerPseudo.name != pseudo.name) return [];
          if (innerPseudo.argument != pseudo.argument) return [];
          return innerSelector.components;

        case 'has':
        case 'host':
        case 'host-context':
        case 'slotted':
          // We can't expand nested selectors here, because each layer adds an
          // additional layer of semantics. For example, `:has(:has(img))`
          // doesn't match `<div><img></div>` but `:has(img)` does.
          return [complex];

        default:
          return [];
      }
    });

    // Older browsers support `:not`, but only with a single complex selector.
    // In order to support those browsers, we break up the contents of a `:not`
    // unless it originally contained a selector list.
    if (pseudo.normalizedName == 'not' && selector.components.length == 1) {
      var result = complexes
          .map((complex) => pseudo.withSelector(SelectorList([complex])))
          .toList();
      return result.isEmpty ? null : result;
    } else {
      return [pseudo.withSelector(SelectorList(complexes))];
    }
  }

  // Removes elements from [selectors] if they're subselectors of other
  // elements.
  //
  // The [isOriginal] callback indicates which selectors are original to the
  // document, and thus should never be trimmed.
  List<ComplexSelector> _trim(List<ComplexSelector> selectors,
      bool isOriginal(ComplexSelector complex)) {
    // Avoid truly horrific quadratic behavior.
    //
    // TODO(nweiz): I think there may be a way to get perfect trimming without
    // going quadratic by building some sort of trie-like data structure that
    // can be used to look up superselectors.
    if (selectors.length > 100) return selectors;

    // This is n² on the sequences, but only comparing between separate
    // sequences should limit the quadratic behavior. We iterate from last to
    // first and reverse the result so that, if two selectors are identical, we
    // keep the first one.
    var result = QueueList<ComplexSelector>();
    var numOriginals = 0;
    outer:
    for (var i = selectors.length - 1; i >= 0; i--) {
      var complex1 = selectors[i];
      if (isOriginal(complex1)) {
        // Make sure we don't include duplicate originals, which could happen if
        // a style rule extends a component of its own selector.
        for (var j = 0; j < numOriginals; j++) {
          if (result[j] == complex1) {
            rotateSlice(result, 0, j + 1);
            continue outer;
          }
        }

        numOriginals++;
        result.addFirst(complex1);
        continue;
      }

      // The maximum specificity of the sources that caused [complex1] to be
      // generated. In order for [complex1] to be removed, there must be another
      // selector that's a superselector of it *and* that has specificity
      // greater or equal to this.
      var maxSpecificity = 0;
      for (var component in complex1.components) {
        if (component is CompoundSelector) {
          maxSpecificity =
              math.max(maxSpecificity, _sourceSpecificityFor(component));
        }
      }

      // Look in [result] rather than [selectors] for selectors after [i]. This
      // ensures that we aren't comparing against a selector that's already been
      // trimmed, and thus that if there are two identical selectors only one is
      // trimmed.
      if (result.any((complex2) =>
          complex2.minSpecificity >= maxSpecificity &&
          complex2.isSuperselector(complex1))) {
        continue;
      }

      if (selectors.take(i).any((complex2) =>
          complex2.minSpecificity >= maxSpecificity &&
          complex2.isSuperselector(complex1))) {
        continue;
      }

      result.addFirst(complex1);
    }
    return result;
  }

  /// Returns the maximum specificity for sources that went into producing
  /// [compound].
  int _sourceSpecificityFor(CompoundSelector compound) {
    var specificity = 0;
    for (var simple in compound.components) {
      specificity = math.max(specificity, _sourceSpecificity[simple] ?? 0);
    }
    return specificity;
  }

  /// Returns a copy of [this] that extends new selectors, as well as a map from
  /// the selectors extended by [this] to the selectors extended by the new
  /// [ExtensionStore].
  Tuple2<ExtensionStore,
      Map<CssValue<SelectorList>, ModifiableCssValue<SelectorList>>> clone() {
    var newSelectors =
        <SimpleSelector, Set<ModifiableCssValue<SelectorList>>>{};
    var newMediaContexts =
        <ModifiableCssValue<SelectorList>, List<CssMediaQuery>>{};
    var oldToNewSelectors =
        <CssValue<SelectorList>, ModifiableCssValue<SelectorList>>{};

    _selectors.forEach((simple, selectors) {
      var newSelectorSet = <ModifiableCssValue<SelectorList>>{};
      newSelectors[simple] = newSelectorSet;

      for (var selector in selectors) {
        var newSelector = ModifiableCssValue(selector.value, selector.span);
        newSelectorSet.add(newSelector);
        oldToNewSelectors[selector] = newSelector;

        var mediaContext = _mediaContexts[selector];
        if (mediaContext != null) newMediaContexts[newSelector] = mediaContext;
      }
    });

    return Tuple2(
        ExtensionStore._(
            newSelectors,
            copyMapOfMap(_extensions),
            copyMapOfList(_extensionsByExtender),
            newMediaContexts,
            Map.identity()..addAll(_sourceSpecificity),
            Set.identity()..addAll(_originals)),
        oldToNewSelectors);
  }
}
