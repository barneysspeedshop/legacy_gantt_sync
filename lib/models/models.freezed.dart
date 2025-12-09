// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
ProtocolMessage _$ProtocolMessageFromJson(
  Map<String, dynamic> json
) {
        switch (json['runtimeType']) {
                  case 'subscribe':
          return _Subscribe.fromJson(
            json
          );
                case 'operation':
          return _Operation.fromJson(
            json
          );
                case 'error':
          return _Error.fromJson(
            json
          );
        
          default:
            throw CheckedFromJsonException(
  json,
  'runtimeType',
  'ProtocolMessage',
  'Invalid union type "${json['runtimeType']}"!'
);
        }
      
}

/// @nodoc
mixin _$ProtocolMessage {

 String get type;
/// Create a copy of ProtocolMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProtocolMessageCopyWith<ProtocolMessage> get copyWith => _$ProtocolMessageCopyWithImpl<ProtocolMessage>(this as ProtocolMessage, _$identity);

  /// Serializes this ProtocolMessage to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProtocolMessage&&(identical(other.type, type) || other.type == type));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type);

@override
String toString() {
  return 'ProtocolMessage(type: $type)';
}


}

/// @nodoc
abstract mixin class $ProtocolMessageCopyWith<$Res>  {
  factory $ProtocolMessageCopyWith(ProtocolMessage value, $Res Function(ProtocolMessage) _then) = _$ProtocolMessageCopyWithImpl;
@useResult
$Res call({
 String type
});




}
/// @nodoc
class _$ProtocolMessageCopyWithImpl<$Res>
    implements $ProtocolMessageCopyWith<$Res> {
  _$ProtocolMessageCopyWithImpl(this._self, this._then);

  final ProtocolMessage _self;
  final $Res Function(ProtocolMessage) _then;

/// Create a copy of ProtocolMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? type = null,}) {
  return _then(_self.copyWith(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [ProtocolMessage].
extension ProtocolMessagePatterns on ProtocolMessage {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( _Subscribe value)?  subscribe,TResult Function( _Operation value)?  operation,TResult Function( _Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Subscribe() when subscribe != null:
return subscribe(_that);case _Operation() when operation != null:
return operation(_that);case _Error() when error != null:
return error(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( _Subscribe value)  subscribe,required TResult Function( _Operation value)  operation,required TResult Function( _Error value)  error,}){
final _that = this;
switch (_that) {
case _Subscribe():
return subscribe(_that);case _Operation():
return operation(_that);case _Error():
return error(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( _Subscribe value)?  subscribe,TResult? Function( _Operation value)?  operation,TResult? Function( _Error value)?  error,}){
final _that = this;
switch (_that) {
case _Subscribe() when subscribe != null:
return subscribe(_that);case _Operation() when operation != null:
return operation(_that);case _Error() when error != null:
return error(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String type,  String channel)?  subscribe,TResult Function( String type,  Map<String, dynamic> data,  int timestamp,  String? actorId)?  operation,TResult Function( String type,  String error)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Subscribe() when subscribe != null:
return subscribe(_that.type,_that.channel);case _Operation() when operation != null:
return operation(_that.type,_that.data,_that.timestamp,_that.actorId);case _Error() when error != null:
return error(_that.type,_that.error);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String type,  String channel)  subscribe,required TResult Function( String type,  Map<String, dynamic> data,  int timestamp,  String? actorId)  operation,required TResult Function( String type,  String error)  error,}) {final _that = this;
switch (_that) {
case _Subscribe():
return subscribe(_that.type,_that.channel);case _Operation():
return operation(_that.type,_that.data,_that.timestamp,_that.actorId);case _Error():
return error(_that.type,_that.error);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String type,  String channel)?  subscribe,TResult? Function( String type,  Map<String, dynamic> data,  int timestamp,  String? actorId)?  operation,TResult? Function( String type,  String error)?  error,}) {final _that = this;
switch (_that) {
case _Subscribe() when subscribe != null:
return subscribe(_that.type,_that.channel);case _Operation() when operation != null:
return operation(_that.type,_that.data,_that.timestamp,_that.actorId);case _Error() when error != null:
return error(_that.type,_that.error);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Subscribe implements ProtocolMessage {
  const _Subscribe({required this.type, required this.channel, final  String? $type}): $type = $type ?? 'subscribe';
  factory _Subscribe.fromJson(Map<String, dynamic> json) => _$SubscribeFromJson(json);

@override final  String type;
 final  String channel;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ProtocolMessage
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SubscribeCopyWith<_Subscribe> get copyWith => __$SubscribeCopyWithImpl<_Subscribe>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SubscribeToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Subscribe&&(identical(other.type, type) || other.type == type)&&(identical(other.channel, channel) || other.channel == channel));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,channel);

@override
String toString() {
  return 'ProtocolMessage.subscribe(type: $type, channel: $channel)';
}


}

/// @nodoc
abstract mixin class _$SubscribeCopyWith<$Res> implements $ProtocolMessageCopyWith<$Res> {
  factory _$SubscribeCopyWith(_Subscribe value, $Res Function(_Subscribe) _then) = __$SubscribeCopyWithImpl;
@override @useResult
$Res call({
 String type, String channel
});




}
/// @nodoc
class __$SubscribeCopyWithImpl<$Res>
    implements _$SubscribeCopyWith<$Res> {
  __$SubscribeCopyWithImpl(this._self, this._then);

  final _Subscribe _self;
  final $Res Function(_Subscribe) _then;

/// Create a copy of ProtocolMessage
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? type = null,Object? channel = null,}) {
  return _then(_Subscribe(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,channel: null == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class _Operation implements ProtocolMessage {
  const _Operation({required this.type, required final  Map<String, dynamic> data, required this.timestamp, this.actorId, final  String? $type}): _data = data,$type = $type ?? 'operation';
  factory _Operation.fromJson(Map<String, dynamic> json) => _$OperationFromJson(json);

@override final  String type;
 final  Map<String, dynamic> _data;
 Map<String, dynamic> get data {
  if (_data is EqualUnmodifiableMapView) return _data;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_data);
}

 final  int timestamp;
 final  String? actorId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ProtocolMessage
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$OperationCopyWith<_Operation> get copyWith => __$OperationCopyWithImpl<_Operation>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$OperationToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Operation&&(identical(other.type, type) || other.type == type)&&const DeepCollectionEquality().equals(other._data, _data)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp)&&(identical(other.actorId, actorId) || other.actorId == actorId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,const DeepCollectionEquality().hash(_data),timestamp,actorId);

@override
String toString() {
  return 'ProtocolMessage.operation(type: $type, data: $data, timestamp: $timestamp, actorId: $actorId)';
}


}

/// @nodoc
abstract mixin class _$OperationCopyWith<$Res> implements $ProtocolMessageCopyWith<$Res> {
  factory _$OperationCopyWith(_Operation value, $Res Function(_Operation) _then) = __$OperationCopyWithImpl;
@override @useResult
$Res call({
 String type, Map<String, dynamic> data, int timestamp, String? actorId
});




}
/// @nodoc
class __$OperationCopyWithImpl<$Res>
    implements _$OperationCopyWith<$Res> {
  __$OperationCopyWithImpl(this._self, this._then);

  final _Operation _self;
  final $Res Function(_Operation) _then;

/// Create a copy of ProtocolMessage
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? type = null,Object? data = null,Object? timestamp = null,Object? actorId = freezed,}) {
  return _then(_Operation(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,data: null == data ? _self._data : data // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as int,actorId: freezed == actorId ? _self.actorId : actorId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
@JsonSerializable()

class _Error implements ProtocolMessage {
  const _Error({this.type = 'error', required this.error, final  String? $type}): $type = $type ?? 'error';
  factory _Error.fromJson(Map<String, dynamic> json) => _$ErrorFromJson(json);

@override@JsonKey() final  String type;
 final  String error;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ProtocolMessage
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ErrorCopyWith<_Error> get copyWith => __$ErrorCopyWithImpl<_Error>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ErrorToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Error&&(identical(other.type, type) || other.type == type)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,error);

@override
String toString() {
  return 'ProtocolMessage.error(type: $type, error: $error)';
}


}

/// @nodoc
abstract mixin class _$ErrorCopyWith<$Res> implements $ProtocolMessageCopyWith<$Res> {
  factory _$ErrorCopyWith(_Error value, $Res Function(_Error) _then) = __$ErrorCopyWithImpl;
@override @useResult
$Res call({
 String type, String error
});




}
/// @nodoc
class __$ErrorCopyWithImpl<$Res>
    implements _$ErrorCopyWith<$Res> {
  __$ErrorCopyWithImpl(this._self, this._then);

  final _Error _self;
  final $Res Function(_Error) _then;

/// Create a copy of ProtocolMessage
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? type = null,Object? error = null,}) {
  return _then(_Error(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
