import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// FFI signatures for raw pointers
typedef SolveCriticalPathFunc =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8> protoInput,
      ffi.Int32 inputLength,
      ffi.Pointer<ffi.Int32> outputLength,
    );
typedef SolveCriticalPath =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8> protoInput,
      int inputLength,
      ffi.Pointer<ffi.Int32> outputLength,
    );

typedef FreeBufferFunc =
    ffi.Void Function(ffi.Pointer<ffi.Uint8> ptr, ffi.Int32 length);
typedef FreeBuffer = void Function(ffi.Pointer<ffi.Uint8> ptr, int length);

class GanttSolverBindings {
  late final ffi.DynamicLibrary _lib;
  late final SolveCriticalPath _solveCriticalPath;
  late final FreeBuffer _freeBuffer;

  GanttSolverBindings() {
    // Determine the library path based on OS
    String libraryPath;
    if (Platform.isLinux) {
      libraryPath = 'libgantt_solver_rs.so';
    } else if (Platform.isMacOS) {
      libraryPath = 'libgantt_solver_rs.dylib';
    } else if (Platform.isWindows) {
      libraryPath = 'gantt_solver_rs.dll';
    } else {
      throw UnsupportedError(
        'Unsupported platform: ${Platform.operatingSystem}',
      );
    }

    try {
      _lib = ffi.DynamicLibrary.open(libraryPath);
    } catch (e) {
      try {
        _lib = ffi.DynamicLibrary.open(
          'gantt_solver_rs/target/release/$libraryPath',
        );
      } catch (_) {
        throw Exception(
          'Failed to load dynamic library: $libraryPath. Error: $e',
        );
      }
    }

    _solveCriticalPath = _lib
        .lookup<ffi.NativeFunction<SolveCriticalPathFunc>>(
          'solve_critical_path',
        )
        .asFunction();
    _freeBuffer = _lib
        .lookup<ffi.NativeFunction<FreeBufferFunc>>('free_buffer')
        .asFunction();
  }

  Uint8List solveCriticalPath(Uint8List requestBytes) {
    // 1. Allocate memory for input buffer
    final inputPtr = calloc<ffi.Uint8>(requestBytes.length);
    final inputList = inputPtr.asTypedList(requestBytes.length);
    inputList.setAll(0, requestBytes);

    // 2. Allocate memory to receive the output length
    final outputLenPtr = calloc<ffi.Int32>();

    try {
      // 3. Call the Rust solver
      final resultPtr = _solveCriticalPath(
        inputPtr,
        requestBytes.length,
        outputLenPtr,
      );
      final outLen = outputLenPtr.value;

      if (resultPtr == ffi.nullptr || outLen <= 0) {
        throw Exception('Solver returned null or 0 length buffer');
      }

      // 4. Copy data to Dart-managed memory
      final resultBytes = Uint8List.fromList(resultPtr.asTypedList(outLen));

      // 5. Free Rust-managed output buffer
      _freeBuffer(resultPtr, outLen);

      return resultBytes;
    } finally {
      calloc.free(inputPtr);
      calloc.free(outputLenPtr);
    }
  }
}
