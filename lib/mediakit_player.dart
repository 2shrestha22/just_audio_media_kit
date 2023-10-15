import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

class MediaKitPlayer extends AudioPlayerPlatform {
  late final Player _player;
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();
  Future<void> get isReady => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  int _currentIndex = 0;

  MediaKitPlayer(super.id) {
    _player = Player(
        configuration: PlayerConfiguration(
      title: 'JustAudioMediaKit',
      logLevel: JustAudioMediaKit.mpvLogLevel,
      ready: () => _readyCompleter.complete(),
    ));

    // store subscriptions to cancel later
    _streamSubscriptions = [
      _player.stream.duration.listen((duration) {
        _processingState = ProcessingStateMessage.ready;
        _updatePlaybackEvent(duration: duration);
      }),
      _player.stream.position.listen((position) {
        _position = position;
        _updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) {
        _logger.fine('isBuffering: $isBuffering');
        _processingState = isBuffering
            ? ProcessingStateMessage.buffering
            : ProcessingStateMessage.ready;
        _updatePlaybackEvent();
      }),
      _player.stream.buffer.listen((buffer) {
        _bufferedPosition = buffer;
        _updatePlaybackEvent();
      }),
      _player.stream.playing.listen((playing) {
        _processingState = ProcessingStateMessage.ready;
        _dataController.add(PlayerDataMessage(playing: playing));
        _updatePlaybackEvent();
      }),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        _processingState = completed
            ? ProcessingStateMessage.completed
            : ProcessingStateMessage.ready;
        _updatePlaybackEvent();
      }),
      _player.stream.error.listen((error) {
        _processingState = ProcessingStateMessage.idle;
        _updatePlaybackEvent();
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        _currentIndex = playlist.index;
        _updatePlaybackEvent();
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        print("MPV: [${event.level}] ${event.prefix}: ${event.text}");
      }),
    ];
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  void _updatePlaybackEvent(
      {Duration? duration, IcyMetadataMessage? icyMetadata}) {
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _bufferedPosition,
      duration: duration,
      icyMetadata: icyMetadata,
      currentIndex: _currentIndex,
      androidAudioSessionId: null,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.fine('load(${request.toMap()})');
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;
    _currentIndex = 0;
    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final as = request.audioSourceMessage as ConcatenatingAudioSourceMessage;
      _currentIndex = request.initialIndex ?? 0;
      final playable = Playlist(
          as.children.map(_convertAudioSourceIntoMediaKit).toList(),
          index: _currentIndex);

      await _player.open(playable);
    } else {
      final playable =
          _convertAudioSourceIntoMediaKit(request.audioSourceMessage);
      _logger.fine('playable is ${playable.toString()}');
      await _player.open(playable);
    }

    if (request.initialPosition != null) {
      _position = request.initialPosition!;
      await _player.seek(request.initialPosition!);
    }

    _updatePlaybackEvent();
    return LoadResponse(duration: _player.state.duration);
  }

  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    if (audioSource is UriAudioSourceMessage) {
      return Media(audioSource.uri, httpHeaders: audioSource.headers);
    } else {
      throw UnsupportedError(
          '${audioSource.runtimeType} is currently not supported');
    }
  }

  @override
  Future<PlayResponse> play(PlayRequest request) {
    return _player.play().then((_) => PlayResponse());
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) {
    return _player.pause().then((_) => PauseResponse());
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) {
    return _player.setRate(request.speed).then((_) => SetSpeedResponse());
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) =>
      _player.setPitch(request.pitch).then((_) => SetPitchResponse());

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) => _player
      .setPlaylistMode(const {
        LoopModeMessage.off: PlaylistMode.none,
        LoopModeMessage.one: PlaylistMode.single,
        LoopModeMessage.all: PlaylistMode.loop,
      }[request.loopMode]!)
      .then((_) => SetLoopModeResponse());

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) =>
      _player
          .setShuffle(request.shuffleMode == ShuffleModeMessage.all)
          .then((_) => SetShuffleModeResponse());

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');
    if (request.index != null) {
      await _player.jump(request.index!);
    }

    _bufferedPosition = Duration.zero;

    if (request.position != null) {
      _position = request.position!;
      await _player.seek(request.position!);
    } else {
      _position = Duration.zero;
    }

    // reset position on seek
    _updatePlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    for (final source in request.children) {
      await _player.add(_convertAudioSourceIntoMediaKit(source));

      final length = _player.state.playlist.medias.length;

      if (length == 0 || length == 1) continue;

      if (request.index < (length - 1) && request.index >= 0) {
        await _player.move(length - 1, request.index);
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    for (var i = 0; i < request.endIndex - request.startIndex; i++) {
      await _player.remove(request.startIndex);
    }

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
          ConcatenatingMoveRequest request) =>
      _player
          .move(request.currentIndex, request.newIndex)
          .then((_) => ConcatenatingMoveResponse());

  Future<void> release() async {
    _logger.info('releasing player resources');
    await _player.dispose();

    // cancel all stream subscriptions
    for (final subscription in _streamSubscriptions) {
      await subscription.cancel();
    }
  }
}