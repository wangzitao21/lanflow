import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';

class AttachmentSelectionPage extends StatefulWidget {
  const AttachmentSelectionPage({
    super.key,
    required this.files,
    required this.onAdd,
  });
  final List<XFile> files;
  final Future<List<XFile>> Function() onAdd;
  @override
  State<AttachmentSelectionPage> createState() =>
      _AttachmentSelectionPageState();
}

class _AttachmentSelectionPageState extends State<AttachmentSelectionPage> {
  late final _files = [...widget.files];
  late final _selected = widget.files.map((file) => file.path).toSet();
  bool _picking = false;
  Future<void> _add() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final next = await widget.onAdd();
      if (!mounted) return;
      setState(() {
        for (final file in next) {
          if (!_files.any((entry) => entry.path == file.path)) _files.add(file);
          _selected.add(file.path);
        }
      });
    } on Object {
      if (mounted) showAppMessage(context, '无法选择文件，请重试');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, '选择附件')),
      actions: [
        TextButton(
          onPressed: _picking
              ? null
              : () => setState(() {
                  if (_selected.length == _files.length) {
                    _selected.clear();
                  } else {
                    _selected.addAll(_files.map((f) => f.path));
                  }
                }),
          child: Text(
            tr(context, _selected.length == _files.length ? '取消全选' : '全选'),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _files.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: .86,
              ),
              itemBuilder: (context, index) {
                final file = _files[index];
                final selected = _selected.contains(file.path);
                final image = RegExp(
                  r'\.(png|jpe?g|webp|gif|heic)$',
                  caseSensitive: false,
                ).hasMatch(file.name);
                return Semantics(
                  selected: selected,
                  label: file.name,
                  button: true,
                  child: InkWell(
                    key: ValueKey('attachment-choice-$index'),
                    onTap: () => setState(() {
                      if (selected) {
                        _selected.remove(file.path);
                      } else {
                        _selected.add(file.path);
                      }
                    }),
                    child: Container(
                      decoration: BoxDecoration(
                        color: ChatPalette.of(context).sidebar,
                        borderRadius: AppCorners.border,
                        border: Border.all(
                          color: selected
                              ? brandGreen
                              : ChatPalette.of(context).divider,
                        ),
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Column(
                              children: [
                                Expanded(
                                  child: image
                                      ? ClipRRect(
                                          borderRadius: AppCorners.border,
                                          child: Image.file(
                                            File(file.path),
                                            width: double.infinity,
                                            fit: BoxFit.cover,
                                            cacheWidth: 360,
                                            errorBuilder: (_, _, _) =>
                                                const Center(
                                                  child: Icon(
                                                    Icons.image_outlined,
                                                    size: 40,
                                                  ),
                                                ),
                                          ),
                                        )
                                      : const Center(
                                          child: Icon(
                                            Icons.insert_drive_file_outlined,
                                            size: 44,
                                          ),
                                        ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    file.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: selected ? brandGreen : Colors.white,
                                border: Border.all(
                                  color: selected ? brandGreen : Colors.black38,
                                  width: 1.5,
                                ),
                              ),
                              child: selected
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 18,
                                    )
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _picking ? null : _add,
                  icon: const Icon(Icons.add),
                  label: Text(tr(context, '继续选择')),
                ),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('confirm-attachments'),
                  onPressed: _picking || _selected.isEmpty
                      ? null
                      : () => Navigator.pop(
                          context,
                          _files
                              .where((f) => _selected.contains(f.path))
                              .toList(),
                        ),
                  child: Text(
                    tr(context, '添加 {count} 个附件', {'count': _selected.length}),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
