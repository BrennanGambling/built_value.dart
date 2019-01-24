// Copyright (c) 2015, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library built_value_generator.source_library;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/analysis/results.dart'; // ignore: implementation_imports
import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value_generator/src/library_elements.dart';
import 'package:built_value_generator/src/serializer_source_class.dart';
import 'package:quiver/iterables.dart';
import 'package:source_gen/source_gen.dart';

part 'serializer_source_library.g.dart';

abstract class SerializerSourceLibrary
    implements Built<SerializerSourceLibrary, SerializerSourceLibraryBuilder> {
  LibraryElement get element;

  factory SerializerSourceLibrary(LibraryElement element) =>
      new _$SerializerSourceLibrary._(element: element);
  SerializerSourceLibrary._();

  @memoized
  ParsedLibraryResult get parsedLibrary =>
      // ignore: deprecated_member_use
      ParsedLibraryResultImpl.tmp(element.library);

  @memoized
  bool get hasSerializers => serializersForAnnotations.isNotEmpty;

  /// Returns a map of `Serializers` declarations; the keys are field names
  /// and the values are the `@SerializersFor` annotations.
  @memoized
  BuiltMap<String, ElementAnnotation> get serializersForAnnotations {
    final result = new MapBuilder<String, ElementAnnotation>();
    final accessors = element.definingCompilationUnit.accessors
        .where((element) =>
            element.isGetter && element.returnType.displayName == 'Serializers')
        .toList();

    for (final accessor in accessors) {
      final annotations = accessor.variable.metadata
          .where((annotation) =>
              annotation.computeConstantValue()?.type?.displayName ==
              'SerializersFor')
          .toList();
      if (annotations.isEmpty) continue;

      result[accessor.name] = annotations.single;
    }

    return result.build();
  }

  /// Returns the set of serializable classes in this library. A serializer
  /// needs to be installed for each of these. A serialized needs to be
  /// generated for each, except where the serializer is marked `custom`.
  @memoized
  BuiltSet<SerializerSourceClass> get sourceClasses {
    final result = new SetBuilder<SerializerSourceClass>();
    final classElements = LibraryElements.getClassElements(element);
    for (final classElement in classElements) {
      final sourceClass = new SerializerSourceClass(classElement);
      if (sourceClass.isSerializable) {
        result.add(sourceClass);
      }
    }
    return result.build();
  }

  /// Returns a map from `Serializers` declaration field names to the classes
  /// that each serializer is required to be able to serialize.
  @memoized
  BuiltSetMultimap<String, SerializerSourceClass> get serializeForClasses {
    final result = new SetMultimapBuilder<String, SerializerSourceClass>();

    for (final field in serializersForAnnotations.keys) {
      final serializersForAnnotation = serializersForAnnotations[field];

      final types = serializersForAnnotation
          .computeConstantValue()
          .getField('types')
          .toListValue()
          ?.map((dartObject) => dartObject.toTypeValue());

      if (types == null) {
        // This only happens if the source code is invalid.
        throw new InvalidGenerationSourceError(
            'Broken @SerializersFor annotation. Are all the types imported?');
      }

      result.addValues(
          field,
          types.map((type) =>
              new SerializerSourceClass(type.element as ClassElement)));
    }
    return result.build();
  }

  /// Returns a map from `Serializers` declaration field names to the
  /// transitive set of serializable classes implied by `serializeForClasses`.
  @memoized
  BuiltSetMultimap<String, SerializerSourceClass>
      get serializeForTransitiveClasses {
    final result = new SetMultimapBuilder<String, SerializerSourceClass>();

    for (final field in serializersForAnnotations.keys) {
      var currentResult = new BuiltSet<SerializerSourceClass>(
          serializeForClasses[field].where(
              (serializerSourceClass) => serializerSourceClass.isSerializable));
      BuiltSet<SerializerSourceClass> expandedResult;

      while (currentResult != expandedResult) {
        currentResult = expandedResult ?? currentResult;
        expandedResult = currentResult.rebuild((b) => b
          ..addAll(currentResult.expand((sourceClass) => sourceClass
              .fieldClasses
              .where((fieldClass) => fieldClass.isSerializable))));
      }

      result.addValues(field, currentResult);
    }

    return result.build();
  }

  bool get needsBuiltJson => sourceClasses.isNotEmpty;

  /// Generates serializer source for this library.
  String generateCode() {
    final errors = concat(sourceClasses
        .map((sourceClass) => sourceClass.computeErrors())
        .toList());

    if (errors.isNotEmpty) throw _makeError(errors);

    return _generateSerializersTopLevelFields() +
        sourceClasses
            .where((sourceClass) => sourceClass.needsGeneratedSerializer)
            .map((sourceClass) => sourceClass.generateSerializerDeclaration())
            .join('\n') +
        sourceClasses
            .where((sourceClass) => sourceClass.needsGeneratedSerializer)
            .map((sourceClass) => sourceClass.generateSerializer())
            .join('\n');
  }

  //TODO: what about nested generic parameters.

  String _generateSerializersTopLevelFields() => serializersForAnnotations.keys
      .map((field) =>
          'Serializers _\$$field = (new Serializers().toBuilder()' +
          (serializeForTransitiveClasses[field]
                  .map((sourceClass) =>
                      sourceClass.generateTransitiveSerializerAdder())
                  .toList()
                    ..sort())
              .join('\n') +
          (serializeForTransitiveClasses[field]
                  .map((sourceClass) =>
                      sourceClass.generateBuilderFactoryAdders(
                          element.definingCompilationUnit))
                  .toList()
                    ..sort())
              .join('\n') +
          //ignore this added block for now
          (serializeForTransitiveClasses[field]
                  .where(
                      (sourceClass) => sourceClass.genericParameters.length > 0)
                  .map((sourceClass) {
                      //serializeForClasses.forEach((k, v) => print("$k, $v"));
                      //serializeForTransitiveClasses.forEach((k, v) => print("$k, $v"));
                      return "";
          }).toList()
                    ..sort())
              .join('\n') +
          ').build();')
      .join('\n');

  ///Generates a [Set] of [BuiltList]s where each of the [BuiltList]s is a
  ///permutation of the possible generic parameters derived from [genericRagged].
  ///
  ///[genericRagged] is a ragged array of possible generic type parameters where
  ///each of the sublists has all of the possible types for the i'th generic
  ///type parameter.
  static Set<BuiltList<String>> _generateGenericPermutationsSet(
      List<List<String>> genericRagged,
      int topLevelPos,
      BuiltList<String> base,
      Set<BuiltList<String>> output) {
    if (genericRagged.length == 0) {
      return output;
    } else if (topLevelPos == (genericRagged.length - 1)) {
      if (genericRagged[topLevelPos].length == 0) {
        output.add(base);
        return output;
      } else {
        genericRagged[topLevelPos].forEach((s) {
          final ListBuilder<String> currentListBuilder = ListBuilder(base)..add(s);
          output.add(currentListBuilder.build());
        });
        return output;
      }
    } else {
      if (genericRagged[topLevelPos].length == 0) {
        return _generateGenericPermutationsSet(
            genericRagged, topLevelPos + 1, base, output);
      } else {
        genericRagged[topLevelPos].forEach((s) {
          final ListBuilder<String> currentListBuilder = ListBuilder(base)..add(s);
          _generateGenericPermutationsSet(genericRagged, topLevelPos + 1,
              currentListBuilder.build(), output);
        });
        return output;
      }
    }
  }

  ///Generates a String of the given [genericTypes] with each type surround by
  ///<> and concatinated for use as generic parameter declaration.
  static String _generateGenericParameterArgumentString(BuiltList<String> genericTypes) {
    final StringBuffer genericArgumentsBuffer = StringBuffer();
    genericTypes.forEach((t) => genericArgumentsBuffer.write(
      "<$t>"
    ));
    return genericArgumentsBuffer.toString();
  }

  ///Generates the code for creation of the List<FullType> for the
  ///builder factory FullType.
  ///
  ///For a type declaration with generic parameters:
  ///  String, int
  ///The generic FullType parameters would be:
  ///```dart
  ///  const [const FullType(String), const FullType(int),]
  /// ```
  static String _generateGenericParameterFullTypeString(BuiltList<String> genericTypes) {
    final StringBuffer genericFullTypesBuffer = StringBuffer();
    genericFullTypesBuffer.write("const [");
    genericTypes.forEach((t) => genericFullTypesBuffer.write(
      "const FullType($t),"
    ));
    genericFullTypesBuffer.write("]");
    return genericFullTypesBuffer.toString();
  }

  ///Generates a builder factory for the given [className] with [genericTypes].
  ///
  ///For class BuiltList with generic types String and int:
  ///```dart
  ///  ..addBuilderFactory(
  ///    const FullType(BuiltList, const [const FullType(String), const FullType(int),]),
  ///    () => BuiltList<String><int>())
  ///```
  static String _generateBuilderFactories(String className, BuiltList<String> genericTypes) {
    final String genericFullType = _generateGenericParameterFullTypeString(genericTypes);
    final String genericArguments = _generateGenericParameterArgumentString(genericTypes);
    return 
    '..addBuilderFactory('
    '  const FullType($className, $genericFullType),'
    '  () => $className$genericArguments())';
  }
}

InvalidGenerationSourceError _makeError(Iterable<String> todos) {
  final message = new StringBuffer(
      'Please make the following changes to use built_value serialization:\n');
  for (var i = 0; i != todos.length; ++i) {
    message.write('\n${i + 1}. ${todos.elementAt(i)}');
  }

  return new InvalidGenerationSourceError(message.toString());
}
