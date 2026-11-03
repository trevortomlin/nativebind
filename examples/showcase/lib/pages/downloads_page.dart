import 'package:flutter/material.dart';

import '../nativebind/nativebind_modules.dart';

/// Downloads: instanced modules created and destroyed by C++, each updated
/// from its own worker thread.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final downloads = Downloads.instance;
  int _started = 0;

  Future<void> _start() async {
    _started++;
    await downloads.start('file-$_started.bin', (4 + _started % 5 * 3) * 1024 * 1024);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          ValueListenableBuilder(
            valueListenable: downloads.active,
            builder: (context, active, _) => ListTile(
              title: Text('$active active'),
              trailing: TextButton(onPressed: downloads.clearFinished, child: const Text('Clear finished')),
            ),
          ),
          const Divider(height: 1),
          // Every live Download instance, ordered by key. The list changes when
          // C++ spawns or destroys one.
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: Download.instances,
              builder: (context, list, _) => list.isEmpty
                  ? const Center(child: Text('No downloads. Tap + to start one.'))
                  : ListView(children: [for (final d in list) DownloadTile(d, key: ValueKey(d.key))]),
            ),
          ),
        ]),
        floatingActionButton: FloatingActionButton(onPressed: _start, tooltip: 'Start a download', child: const Icon(Icons.add)),
      );
}

class DownloadTile extends StatelessWidget {
  const DownloadTile(this.download, {super.key});

  final Download download;

  @override
  Widget build(BuildContext context) {
    final d = download;
    return ListenableBuilder(
      listenable: Listenable.merge([d.state, d.progress, d.received, d.speed]),
      builder: (context, _) {
        final state = d.state.value;
        final unit = d.speed.meta.attr<String>('unit') ?? '';
        return Card(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(d.name.value, style: Theme.of(context).textTheme.titleMedium)),
                Text(state.label),
                if (state == DownloadState.running)
                  IconButton(onPressed: d.pause, icon: const Icon(Icons.pause), tooltip: 'Pause')
                else if (state == DownloadState.paused)
                  IconButton(onPressed: d.resume, icon: const Icon(Icons.play_arrow), tooltip: 'Resume'),
                IconButton(
                  onPressed: () => Downloads.instance.remove(d.key),
                  icon: const Icon(Icons.close),
                  tooltip: 'Remove',
                ),
              ]),
              LinearProgressIndicator(value: d.progress.value),
              const SizedBox(height: 4),
              Text('${_mib(d.received.value)} of ${_mib(d.total.value)} MiB'),
              if (state != DownloadState.done)
                Row(children: [
                  Text('${d.speed.meta.label}: ${d.speed.value} $unit'),
                  Expanded(
                    child: Slider(
                      value: d.speed.value.toDouble(),
                      min: d.speed.meta.min,
                      max: d.speed.meta.max,
                      divisions: ((d.speed.meta.max - d.speed.meta.min) / d.speed.meta.step).round(),
                      onChanged: (v) => d.speed.value = v.round(),
                    ),
                  ),
                ]),
            ]),
          ),
        );
      },
    );
  }
}

String _mib(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
