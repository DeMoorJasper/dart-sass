// Copyright 2016 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:math' as math;

import 'package:charcode/charcode.dart';
import 'package:collection/collection.dart';
import 'package:source_span/source_span.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:string_scanner/string_scanner.dart';
import 'package:term_glyph/term_glyph.dart' as glyph;

import 'util/character.dart';

/// The URL used in stack traces when no source URL is available.
final _noSourceUrl = Uri.parse("-");

/// Converts [iter] into a sentence, separating each word with [conjunction].
String toSentence(Iterable<Object> iter, [String? conjunction]) {
  conjunction ??= "and";
  if (iter.length == 1) return iter.first.toString();
  return iter.take(iter.length - 1).join(", ") + " $conjunction ${iter.last}";
}

/// Returns [string] with every line indented [indentation] spaces.
String indent(String string, int indentation) =>
    string.split("\n").map((line) => (" " * indentation) + line).join("\n");

/// Returns [name] if [number] is 1, or the plural of [name] otherwise.
///
/// By default, this just adds "s" to the end of [name] to get the plural. If
/// [plural] is passed, that's used instead.
String pluralize(String name, int number, {String? plural}) {
  if (number == 1) return name;
  if (plural != null) return plural;
  return '${name}s';
}

/// Returns `a $word` or `an $word` depending on whether [word] starts with a
/// vowel.
String a(String word) =>
    [$a, $e, $i, $o, $u].contains(word.codeUnitAt(0)) ? "an $word" : "a $word";

/// Returns a bulleted list of items in [bullets].
String bulletedList(Iterable<String> bullets) {
  return bullets.map((element) {
    var lines = element.split("\n");
    return "${glyph.bullet} ${lines.first}" +
        (lines.length > 1 ? "\n" + indent(lines.skip(1).join("\n"), 2) : "");
  }).join("\n");
}

/// Returns the number of times [codeUnit] appears in [string].
int countOccurrences(String string, int codeUnit) {
  var count = 0;
  for (var i = 0; i < string.length; i++) {
    if (string.codeUnitAt(i) == codeUnit) count++;
  }
  return count;
}

/// Like [String.trim], but only trims ASCII whitespace.
///
/// If [excludeEscape] is `true`, this doesn't trim whitespace included in a CSS
/// escape.
String trimAscii(String string, {bool excludeEscape = false}) {
  var start = _firstNonWhitespace(string);
  return start == null
      ? ""
      : string.substring(
          start, _lastNonWhitespace(string, excludeEscape: excludeEscape)! + 1);
}

/// Like [String.trimLeft], but only trims ASCII whitespace.
String trimAsciiLeft(String string) {
  var start = _firstNonWhitespace(string);
  return start == null ? "" : string.substring(start);
}

/// Like [String.trimRight], but only trims ASCII whitespace.
///
/// If [excludeEscape] is `true`, this doesn't trim whitespace included in a CSS
/// escape.
String trimAsciiRight(String string, {bool excludeEscape = false}) {
  var end = _lastNonWhitespace(string, excludeEscape: excludeEscape);
  return end == null ? "" : string.substring(0, end + 1);
}

/// Returns the index of the first character in [string] that's not ASCII
/// whitespace, or [null] if [string] is entirely spaces.
int? _firstNonWhitespace(String string) {
  for (var i = 0; i < string.length; i++) {
    if (!isWhitespace(string.codeUnitAt(i))) return i;
  }
  return null;
}

/// Returns the index of the last character in [string] that's not ASCII
/// whitespace, or [null] if [string] is entirely spaces.
///
/// If [excludeEscape] is `true`, this doesn't move past whitespace that's
/// included in a CSS escape.
int? _lastNonWhitespace(String string, {bool excludeEscape = false}) {
  for (var i = string.length - 1; i >= 0; i--) {
    var codeUnit = string.codeUnitAt(i);
    if (!isWhitespace(codeUnit)) {
      if (excludeEscape &&
          i != 0 &&
          i != string.length &&
          codeUnit == $backslash) {
        return i + 1;
      } else {
        return i;
      }
    }
  }
  return null;
}

/// Returns whether [member] is a public member name.
///
/// Assumes that [member] is a valid Sass identifier.
bool isPublic(String member) {
  var start = member.codeUnitAt(0);
  return start != $dash && start != $underscore;
}

/// Flattens the first level of nested arrays in [iterable].
///
/// The return value is ordered first by index in the nested iterable, then by
/// the index *of* that iterable in [iterable]. For example,
/// `flattenVertically([["1a", "1b"], ["2a", "2b"]])` returns `["1a", "2a",
/// "1b", "2b"]`.
List<T> flattenVertically<T>(Iterable<Iterable<T>> iterable) {
  var queues = iterable.map((inner) => QueueList.from(inner)).toList();
  if (queues.length == 1) return queues.first;

  var result = <T>[];
  while (queues.isNotEmpty) {
    queues.removeWhere((queue) {
      result.add(queue.removeFirst());
      return queue.isEmpty;
    });
  }
  return result;
}

/// Returns the first element of [iterable], or `null` if the iterable is empty.
// TODO(nweiz): Use package:collection
T? firstOrNull<T>(Iterable<T> iterable) {
  var iterator = iterable.iterator;
  return iterator.moveNext() ? iterator.current : null;
}

/// Converts [codepointIndex] to a code unit index, relative to [string].
///
/// A codepoint index is the index in pure Unicode codepoints; a code unit index
/// is an index into a UTF-16 string.
int codepointIndexToCodeUnitIndex(String string, int codepointIndex) {
  var codeUnitIndex = 0;
  for (var i = 0; i < codepointIndex; i++) {
    if (isHighSurrogate(string.codeUnitAt(codeUnitIndex++))) codeUnitIndex++;
  }
  return codeUnitIndex;
}

/// Converts [codeUnitIndex] to a codepoint index, relative to [string].
///
/// A codepoint index is the index in pure Unicode codepoints; a code unit index
/// is an index into a UTF-16 string.
int codeUnitIndexToCodepointIndex(String string, int codeUnitIndex) {
  var codepointIndex = 0;
  for (var i = 0; i < codeUnitIndex; i++) {
    codepointIndex++;
    if (isHighSurrogate(string.codeUnitAt(i))) i++;
  }
  return codepointIndex;
}

/// Returns whether [iterable1] and [iterable2] have the same contents.
bool iterableEquals(Iterable<Object> iterable1, Iterable<Object> iterable2) =>
    const IterableEquality<Object>().equals(iterable1, iterable2);

/// Returns a hash code for [iterable] that matches [iterableEquals].
int iterableHash(Iterable<Object> iterable) =>
    const IterableEquality<Object>().hash(iterable);

/// Returns whether [list1] and [list2] have the same contents.
bool listEquals(List<Object?>? list1, List<Object?>? list2) =>
    const ListEquality<Object?>().equals(list1, list2);

/// Returns a hash code for [list] that matches [listEquals].
int listHash(List<Object> list) => const ListEquality<Object>().hash(list);

/// Returns whether [map1] and [map2] have the same contents.
bool mapEquals(Map<Object, Object> map1, Map<Object, Object> map2) =>
    const MapEquality<Object, Object>().equals(map1, map2);

/// Returns a hash code for [map] that matches [mapEquals].
int mapHash(Map<Object, Object> map) =>
    const MapEquality<Object, Object>().hash(map);

/// Returns a stack frame for the given [span] with the given [member] name.
///
/// By default, the frame's URL is set to `span.sourceUrl`. However, if [url] is
/// passed, it's used instead.
Frame frameForSpan(SourceSpan span, String member, {Uri? url}) => Frame(
    url ?? span.sourceUrl ?? _noSourceUrl,
    span.start.line + 1,
    span.start.column + 1,
    member);

/// Returns the variable name (including the leading `$`) from a [span] that
/// covers a variable declaration, which includes the variable name as well as
/// the colon and expression following it.
///
/// This isn't particularly efficient, and should only be used for error
/// messages.
String declarationName(FileSpan span) {
  var text = span.text;
  return trimAsciiRight(text.substring(0, text.indexOf(":")));
}

/// Returns [name] without a vendor prefix.
///
/// If [name] has no vendor prefix, it's returned as-is.
String unvendor(String name) {
  if (name.length < 2) return name;
  if (name.codeUnitAt(0) != $dash) return name;
  if (name.codeUnitAt(1) == $dash) return name;

  for (var i = 2; i < name.length; i++) {
    if (name.codeUnitAt(i) == $dash) return name.substring(i + 1);
  }
  return name;
}

/// Returns whether [string1] and [string2] are equal, ignoring ASCII case.
bool equalsIgnoreCase(String? string1, String? string2) {
  if (identical(string1, string2)) return true;
  if (string1 == null || string2 == null) return false;
  if (string1.length != string2.length) return false;

  for (var i = 0; i < string1.length; i++) {
    if (!characterEqualsIgnoreCase(
        string1.codeUnitAt(i), string2.codeUnitAt(i))) {
      return false;
    }
  }
  return true;
}

/// Returns whether [string] starts with [prefix], ignoring ASCII case.
bool startsWithIgnoreCase(String string, String prefix) {
  if (string.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (!characterEqualsIgnoreCase(
        string.codeUnitAt(i), prefix.codeUnitAt(i))) {
      return false;
    }
  }
  return true;
}

/// Destructively updates every element of [list] with the result of [function].
void mapInPlace<T>(List<T> list, T function(T element)) {
  for (var i = 0; i < list.length; i++) {
    list[i] = function(list[i]);
  }
}

/// Returns the longest common subsequence between [list1] and [list2].
///
/// If there are more than one equally long common subsequence, returns the one
/// which starts first in [list1].
///
/// If [select] is passed, it's used to check equality between elements in each
/// list. If it returns `null`, the elements are considered unequal; otherwise,
/// it should return the element to include in the return value.
List<T> longestCommonSubsequence<T>(List<T> list1, List<T> list2,
    {T? select(T element1, T element2)?}) {
  select ??= (element1, element2) => element1 == element2 ? element1 : null;

  var lengths = List.generate(
      list1.length + 1, (_) => List.filled(list2.length + 1, 0),
      growable: false);

  var selections = List<List<T?>>.generate(
      list1.length, (_) => List<T?>.filled(list2.length, null),
      growable: false);

  for (var i = 0; i < list1.length; i++) {
    for (var j = 0; j < list2.length; j++) {
      var selection = select(list1[i], list2[j]);
      selections[i][j] = selection;
      lengths[i + 1][j + 1] = selection == null
          ? math.max(lengths[i + 1][j], lengths[i][j + 1])
          : lengths[i][j] + 1;
    }
  }

  List<T> backtrack(int i, int j) {
    if (i == -1 || j == -1) return [];
    var selection = selections[i][j];
    if (selection != null) return backtrack(i - 1, j - 1)..add(selection);

    return lengths[i + 1][j] > lengths[i][j + 1]
        ? backtrack(i, j - 1)
        : backtrack(i - 1, j);
  }

  return backtrack(list1.length - 1, list2.length - 1);
}

/// Removes the first value in [list] that matches [test].
///
/// If [orElse] is passed, calls it if no value matches.
void removeFirstWhere<T>(List<T> list, bool test(T value), {void orElse()?}) {
  for (var i = 0; i < list.length; i++) {
    if (!test(list[i])) continue;
    list.removeAt(i);
    return;
  }

  if (orElse != null) orElse();
}

/// Like [Map.addAll], but for two-layer maps.
///
/// This avoids copying inner maps from [source] if possible.
void mapAddAll2<K1, K2, V>(
    Map<K1, Map<K2, V>> destination, Map<K1, Map<K2, V>> source) {
  source.forEach((key, inner) {
    var innerDestination = destination[key];
    if (innerDestination != null) {
      innerDestination.addAll(inner);
    } else {
      destination[key] = inner;
    }
  });
}

/// Sets all [keys] in [map] to [value].
void setAll<K, V>(Map<K, V> map, Iterable<K> keys, V value) {
  for (var key in keys) {
    map[key] = value;
  }
}

/// Rotates the element in list from [start] (inclusive) to [end] (exclusive)
/// one index higher, looping the final element back to [start].
void rotateSlice(List<Object> list, int start, int end) {
  var element = list[end - 1];
  for (var i = start; i < end; i++) {
    var next = list[i];
    list[i] = element;
    element = next;
  }
}

/// Like [Iterable.map] but for an asynchronous [callback].
Future<Iterable<F>> mapAsync<E, F>(
        Iterable<E> iterable, Future<F> callback(E value)) async =>
    [for (var element in iterable) await callback(element)];

/// Like [Map.putIfAbsent], but for an asynchronous [ifAbsent].
///
/// Note that this is *not* safe to call in parallel on the same map with the
/// same key.
Future<V> putIfAbsentAsync<K, V>(
    Map<K, V> map, K key, Future<V> ifAbsent()) async {
  if (map.containsKey(key)) return map[key] as V;
  var value = await ifAbsent();
  map[key] = value;
  return value;
}

/// Returns a deep copy of a map that contains maps.
Map<K1, Map<K2, V>> copyMapOfMap<K1, K2, V>(Map<K1, Map<K2, V>> map) =>
    {for (var entry in map.entries) entry.key: Map.of(entry.value)};

/// Returns a deep copy of a map that contains lists.
Map<K, List<E>> copyMapOfList<K, E>(Map<K, List<E>> map) =>
    {for (var entry in map.entries) entry.key: entry.value.toList()};

/// Consumes an escape sequence from [scanner] and returns the character it
/// represents.
int consumeEscapedCharacter(StringScanner scanner) {
  // See https://drafts.csswg.org/css-syntax-3/#consume-escaped-code-point.

  scanner.expectChar($backslash);
  var first = scanner.peekChar();
  if (first == null) {
    return 0xFFFD;
  } else if (isNewline(first)) {
    scanner.error("Expected escape sequence.");
  } else if (isHex(first)) {
    var value = 0;
    for (var i = 0; i < 6; i++) {
      var next = scanner.peekChar();
      if (next == null || !isHex(next)) break;
      value = (value << 4) + asHex(scanner.readChar());
    }
    if (isWhitespace(scanner.peekChar())) scanner.readChar();

    if (value == 0 ||
        (value >= 0xD800 && value <= 0xDFFF) ||
        value >= 0x10FFFF) {
      return 0xFFFD;
    } else {
      return value;
    }
  } else {
    return scanner.readChar();
  }
}

extension MapExtension<K, V> on Map<K, V> {
  /// If [this] doesn't contain the given [key], sets that key to [value] and
  /// returns it.
  ///
  /// Otherwise, calls [merge] with the existing value and [value] and sets
  /// [key] to the result.
  V putOrMerge(K key, V value, V Function(V oldValue, V newValue) merge) =>
      containsKey(key)
          ? this[key] = merge(this[key]!, value)
          : this[key] = value;
}
