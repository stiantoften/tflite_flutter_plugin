// @dart=2.11
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:quiver/check.dart';

import 'bindings/tensor.dart';
import 'bindings/types.dart';

import 'ffi/helper.dart';
import 'quanitzation_params.dart';
import 'util/list_shape_extension.dart';

export 'bindings/types.dart' show TfLiteType;

/// TensorFlowLite tensor.
class Tensor {
  final Pointer<TfLiteTensor> _tensor;

  Tensor(this._tensor) {
    checkNotNull(_tensor);
  }

  /// Name of the tensor element.
  String get name => tfLiteTensorName(_tensor).toDartString();

  /// Data type of the tensor element.
  TfLiteType get type => tfLiteTensorType(_tensor);

  /// Dimensions of the tensor.
  List<int> get shape => List.generate(
      tfLiteTensorNumDims(_tensor), (i) => tfLiteTensorDim(_tensor, i));

  /// Underlying data buffer as bytes.
  Uint8List get data {
    final data = cast<Uint8>(tfLiteTensorData(_tensor));
//    checkState(isNotNull(data), message: 'Tensor data is null.');
    return UnmodifiableUint8ListView(
        data?.asTypedList(tfLiteTensorByteSize(_tensor)));
  }

  /// Quantization Params associated with the model, [only Android]
  QuantizationParams get params {
    if (_tensor != null) {
      final ref = tfLiteTensorQuantizationParams(_tensor).ref;
      return QuantizationParams(ref.scale, ref.zeroPoint);
    } else {
      return QuantizationParams(0.0, 0);
    }
  }

  /// Updates the underlying data buffer with new bytes.
  ///
  /// The size must match the size of the tensor.
  set data(Uint8List bytes) {
    final tensorByteSize = tfLiteTensorByteSize(_tensor);
    checkArgument(tensorByteSize == bytes.length);
    final data = cast<Uint8>(tfLiteTensorData(_tensor));
    checkState(isNotNull(data), message: 'Tensor data is null.');
    final externalTypedData = data.asTypedList(tensorByteSize);
    externalTypedData.setRange(0, tensorByteSize, bytes);
  }

  /// Returns number of dimensions
  int numDimensions() {
    return tfLiteTensorNumDims(_tensor);
  }

  /// Returns the size, in bytes, of the tensor data.
  int numBytes() {
    return tfLiteTensorByteSize(_tensor);
  }

  /// Returns the number of elements in a flattened (1-D) view of the tensor.
  int numElements() {
    return computeNumElements(shape);
  }

  /// Returns the number of elements in a flattened (1-D) view of the tensor's shape.
  static int computeNumElements(List<int> shape) {
    var n = 1;
    for (var i = 0; i < shape.length; i++) {
      n *= shape[i];
    }
    return n;
  }

  /// Returns shape of an object as an int list
  static List<int> computeShapeOf(Object o) {
    var size = computeNumDimensions(o);
    var dimensions = List.filled(size, 0, growable: false);
    fillShape(o, 0, dimensions);
    return dimensions;
  }

  /// Returns the number of dimensions of a multi-dimensional array, otherwise 0.
  static int computeNumDimensions(Object o) {
    if (o == null || !(o is List)) {
      return 0;
    }
    if ((o as List).isEmpty) {
      throw ArgumentError('Array lengths cannot be 0.');
    }
    return 1 + computeNumDimensions((o as List).elementAt(0));
  }

  /// Recursively populates the shape dimensions for a given (multi-dimensional) array)
  static void fillShape(Object o, int dim, List<int> shape) {
    if (shape == null || dim == shape.length) {
      return;
    }
    final len = (o as List).length;
    if (shape[dim] == 0) {
      shape[dim] = len;
    } else if (shape[dim] != len) {
      throw ArgumentError(
          'Mismatched lengths ${shape[dim]} and $len in dimension $dim');
    }
    for (var i = 0; i < len; ++i) {
      fillShape((o as List).elementAt(0), dim + 1, shape);
    }
  }

  /// Returns data type of given object
  static TfLiteType dataTypeOf(Object o) {
    while (o is List) {
      o = (o as List).elementAt(0);
    }
    var c = o;
    if (c is double) {
      return TfLiteType.float32;
    } else if (c is int) {
      return TfLiteType.int32;
    } else if (c is String) {
      return TfLiteType.string;
    } else if (c is bool) {
      return TfLiteType.bool;
    }
    throw ArgumentError(
        'DataType error: cannot resolve DataType of ${o.runtimeType}');
  }

  void setTo(Object src) {
    var bytes = _convertObjectToBytes(src);
    var size = bytes.length;
    final ptr = calloc<Uint8>(size);
    checkState(isNotNull(ptr), message: 'unallocated');
    final externalTypedData = ptr.asTypedList(size);
    externalTypedData.setRange(0, bytes.length, bytes);
    checkState(tfLiteTensorCopyFromBuffer(_tensor, ptr.cast(), bytes.length) ==
        TfLiteStatus.ok);
    calloc.free(ptr);
  }

  Object copyTo(Object dst) {
    var size = tfLiteTensorByteSize(_tensor);
    final ptr = calloc<Uint8>(size);
    checkState(isNotNull(ptr), message: 'unallocated');
    final externalTypedData = ptr.asTypedList(size);
    checkState(
        tfLiteTensorCopyToBuffer(_tensor, ptr.cast(), size) == TfLiteStatus.ok);
    // Clone the data, because once `free(ptr)`, `externalTypedData` will be
    // volatile
    final bytes = externalTypedData.sublist(0);
    data = bytes;
    var obj;
    if (dst is Uint8List) {
      obj = bytes;
    } else if (dst is ByteBuffer) {
      var bdata = dst.asByteData();
      for (int i = 0; i < bdata.lengthInBytes; i++) {
        bdata.setUint8(i, bytes[i]);
      }
    } else {
      obj = _convertBytesToObject(bytes);
    }
    calloc.free(ptr);
    if (obj is List && dst is List) {
      _duplicateList(obj, dst);
    } else {
      dst = obj;
    }
    return obj;
  }

  Uint8List _convertObjectToBytes(Object o) {
    if (o is Uint8List) {
      return o;
    }
    if (o is ByteBuffer) {
      return o.asUint8List();
    }
    var bytes = <int>[];
    if (o is List) {
      for (var e in o) {
        bytes.addAll(_convertObjectToBytes(e));
      }
    } else {
      return _convertElementToBytes(o);
    }
    return Uint8List.fromList(bytes);
  }

  Uint8List _convertElementToBytes(Object o) {
    //TODO: add conversions for rest of the types
    if (type == TfLiteType.float32) {
      if (o is double) {
        var buffer = Uint8List(4).buffer;
        var bdata = ByteData.view(buffer);
        bdata.setFloat32(0, o, Endian.little);
        return buffer.asUint8List();
      } else {
        throw ArgumentError(
            'The input element is ${o.runtimeType} while tensor data type is ${TfLiteType.float32}');
      }
    } else if (type == TfLiteType.int32) {
      if (o is int) {
        var buffer = Uint8List(4).buffer;
        var bdata = ByteData.view(buffer);
        bdata.setInt32(0, o, Endian.little);
        return buffer.asUint8List();
      } else {
        throw ArgumentError(
            'The input element is ${o.runtimeType} while tensor data type is ${TfLiteType.int32}');
      }
    } else if (type == TfLiteType.int64) {
      if (o is int) {
        var buffer = Uint8List(8).buffer;
        var bdata = ByteData.view(buffer);
        bdata.setInt64(0, o, Endian.big);
        return buffer.asUint8List();
      } else {
        throw ArgumentError(
            'The input element is ${o.runtimeType} while tensor data type is ${TfLiteType.int32}');
      }
    } else if (type == TfLiteType.int16) {
      if (o is int) {
        var buffer = Uint8List(2).buffer;
        var bdata = ByteData.view(buffer);
        bdata.setInt16(0, o, Endian.little);
        return buffer.asUint8List();
      } else {
        throw ArgumentError(
            'The input element is ${o.runtimeType} while tensor data type is ${TfLiteType.int32}');
      }
    } else if (type == TfLiteType.float16) {
      if (o is double) {
        var buffer = Uint8List(4).buffer;
        var bdata = ByteData.view(buffer);
        bdata.setFloat32(0, o, Endian.little);
        return buffer.asUint8List().sublist(0, 2);
      } else {
        throw ArgumentError(
            'The input element is ${o.runtimeType} while tensor data type is ${TfLiteType.float32}');
      }
    } else if (type == TfLiteType.int8) {
      if (o is int) {
        var buffer = Uint8List(1).buffer;
        var bdata = ByteData.view(buffer);
        bdata.setInt8(0, o);
        return buffer.asUint8List();
      } else {
        throw ArgumentError(
            'The input element is ${o.runtimeType} while tensor data type is ${TfLiteType.float32}');
      }
    } else {
      throw ArgumentError(
          'The input data type ${o.runtimeType} is unsupported');
    }
  }

  Object _convertBytesToObject(Uint8List bytes) {
    // stores flattened data
    var list = [];
    //TODO: add conversions for the rest of the types
    if (type == TfLiteType.int32) {
      for (var i = 0; i < bytes.length; i += 4) {
        list.add(ByteData.view(bytes.buffer).getInt32(i, Endian.little));
      }
      return list.reshape<int>(shape);
    } else if (type == TfLiteType.float32) {
      for (var i = 0; i < bytes.length; i += 4) {
        list.add(ByteData.view(bytes.buffer).getFloat32(i, Endian.little));
      }
      return list.reshape<double>(shape);
    } else if (type == TfLiteType.int16) {
      for (var i = 0; i < bytes.length; i += 2) {
        list.add(ByteData.view(bytes.buffer).getInt16(i, Endian.little));
      }
      return list.reshape<int>(shape);
    } else if (type == TfLiteType.float16) {
      Uint8List list32 = Uint8List(bytes.length * 2);
      for (var i = 0; i < bytes.length; i += 2) {
        list32[i] = bytes[i];
        list32[i + 1] = bytes[i + 1];
      }
      for (var i = 0; i < list32.length; i += 4) {
        list.add(ByteData.view(list32.buffer).getFloat32(i, Endian.little));
      }
      return list.reshape<double>(shape);
    } else if (type == TfLiteType.int8) {
      for (var i = 0; i < bytes.length; i += 1) {
        list.add(ByteData.view(bytes.buffer).getInt8(i));
      }
      return list.reshape<int>(shape);
    } else if (type == TfLiteType.int64) {
      for (var i = 0; i < bytes.length; i += 8) {
        list.add(ByteData.view(bytes.buffer).getInt64(i));
      }
      return list.reshape<int>(shape);
    }
    return null;
  }

  void _duplicateList(List obj, List dst) {
    var objShape = obj.shape;
    var dstShape = dst.shape;
    var equal = true;
    if (objShape.length == dst.shape.length) {
      for (var i = 0; i < objShape.length; i++) {
        if (objShape[i] != dstShape[i]) {
          equal = false;
          break;
        }
      }
    } else {
      equal = false;
    }
    if (equal == false) {
      throw ArgumentError(
          'Output object shape mismatch, interpreter returned output of shape: ${obj.shape} while shape of output provided as argument in run is: ${dst.shape}');
    }
    for (var i = 0; i < obj.length; i++) {
      dst[i] = obj[i];
    }
  }

  List<int> getInputShapeIfDifferent(Object input) {
    if (input == null) {
      return null;
    }
    if (input is ByteBuffer || input is Uint8List) {
      return null;
    }

    final inputShape = computeShapeOf(input);
    if (inputShape == shape) {
      return null;
    }
    return inputShape;
  }

  @override
  String toString() {
    return 'Tensor{_tensor: $_tensor, name: $name, type: $type, shape: $shape, data:  ${data.length}';
  }
}
