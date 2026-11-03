import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nativebind/nativebind.dart';

import '../nativebind/nativebind_modules.dart';

/// Player: enums, a list of structs, edit sessions for dragging, and calls
/// that return values.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final player = Player.instance;
  late final StreamSubscription<String> _changes;
  PropertyEdit<double>? _volumeEdit;
  double? _scrub; // position while the user drags the seek bar
  int _added = 0;

  @override
  void initState() {
    super.initState();
    _changes = player.trackChanged.listen((title) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Now playing: $title'), duration: const Duration(seconds: 1)));
    });
  }

  @override
  void dispose() {
    _changes.cancel();
    _volumeEdit?.cancel();
    super.dispose();
  }

  Future<void> _addTrack() async {
    _added++;
    final id = await player.add('New track $_added', 'Added from Dart', 60 + 30 * _added);
    debugPrint('C++ gave the track id $id');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        const SizedBox(height: 16),
        // Several values in one builder: rebuild when any of them changes.
        ListenableBuilder(
          listenable: Listenable.merge([player.title, player.state, player.position, player.duration]),
          builder: (context, _) {
            final playing = player.state.value == PlayState.playing;
            final duration = player.duration.value;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(children: [
                Text(player.title.value.isEmpty ? 'Nothing queued' : player.title.value, style: text.headlineSmall),
                Text(player.state.value.label, style: text.labelLarge),
                Slider(
                  value: (_scrub ?? player.position.value).clamp(0, duration),
                  max: duration > 0 ? duration : 1,
                  onChanged: duration > 0 ? (v) => setState(() => _scrub = v) : null,
                  onChangeEnd: (v) async {
                    await player.seek(v);
                    setState(() => _scrub = null);
                  },
                ),
                Text('${_time(_scrub ?? player.position.value)} / ${_time(duration)}'),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton.filled(
                    iconSize: 36,
                    onPressed: playing ? player.pause : player.play,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    tooltip: playing ? 'Pause' : 'Play',
                  ),
                  IconButton(onPressed: player.next, icon: const Icon(Icons.skip_next), tooltip: 'Next'),
                ]),
              ]),
            );
          },
        ),
        // Dragging uses an edit session: the finger wins over incoming values
        // and writes are throttled to 10 per second.
        ValueListenableBuilder(
          valueListenable: player.volume,
          builder: (context, volume, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(children: [
              const Icon(Icons.volume_down),
              Expanded(
                child: Slider(
                  value: volume,
                  onChangeStart: (_) => _volumeEdit = player.volume.beginEdit(),
                  onChanged: (v) => _volumeEdit?.update(v),
                  onChangeEnd: (v) {
                    _volumeEdit?.commit(v);
                    _volumeEdit = null;
                  },
                ),
              ),
              SizedBox(width: 48, child: Text('${(volume * 100).round()} %')),
            ]),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: player.shuffle,
          builder: (context, shuffle, _) => SwitchListTile(
            title: const Text('Shuffle'),
            value: shuffle,
            onChanged: (v) => player.shuffle.value = v,
          ),
        ),
        const Divider(),
        // A BoundList is a List; C++ sends only the rows that changed.
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: player.queue,
            builder: (context, queue, _) => ListView(children: [
              for (final track in queue)
                ListTile(
                  key: ValueKey(track.id),
                  title: Text(track.title),
                  subtitle: Text('${track.artist} · ${_time(track.length.inSeconds.toDouble())}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      onPressed: () => player.toggleLike(track.id),
                      icon: Icon(track.liked ? Icons.favorite : Icons.favorite_border),
                      tooltip: 'Like',
                    ),
                    IconButton(
                      onPressed: () => player.remove(track.id),
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove',
                    ),
                  ]),
                ),
              ListTile(leading: const Icon(Icons.add), title: const Text('Add a track'), onTap: _addTrack),
            ]),
          ),
        ),
      ],
    );
  }
}

String _time(double seconds) {
  final s = seconds.floor();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
