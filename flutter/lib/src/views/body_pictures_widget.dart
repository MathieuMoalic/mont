import 'dart:convert';
import 'package:flutter/material.dart';
import '../api.dart' as api;
import '../models.dart';

class BodyPicturesSection extends StatefulWidget {
  final Function? onRefresh;
  final Future<void> Function()? onAdd;

  const BodyPicturesSection({super.key, this.onRefresh, this.onAdd});

  @override
  State<BodyPicturesSection> createState() => _BodyPicturesSectionState();
}

class _BodyPicturesSectionState extends State<BodyPicturesSection> {
  List<BodyPicture>? _pictures;
  String? _error;
  bool _loading = true;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _loadPictures();
  }

  Future<void> _loadPictures() async {
    try {
      final pics = await api.listBodyPictures();
      if (mounted) {
        setState(() {
          _pictures = pics;
          _error = null;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _showPictureViewer(BodyPicture picture) {
    showDialog(
      context: context,
      builder: (ctx) => PictureViewerDialog(
        picture: picture,
        allPictures: _pictures ?? [],
        onDelete: () {
          Navigator.pop(ctx);
          _loadPictures();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            'Error: $_error',
            style: TextStyle(color: Colors.red.shade700),
          ),
        ),
      );
    }

    final pictures = _pictures ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                'Progress Pictures',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (widget.onAdd != null) ...[
                const Spacer(),
                IconButton(
                  tooltip: 'Add progress picture',
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    await widget.onAdd?.call();
                    await _loadPictures();
                  },
                  icon: const Icon(Icons.add),
                ),
              ],
            ],
          ),
        ),
        if (pictures.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(
                'No progress pictures yet',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ),
          )
        else
          PictureCalendar(pictures: pictures, onDayTap: _showPictureViewer),
      ],
    );
  }
}

class PictureCalendar extends StatefulWidget {
  final List<BodyPicture> pictures;
  final Function(BodyPicture) onDayTap;

  const PictureCalendar({
    super.key,
    required this.pictures,
    required this.onDayTap,
  });

  @override
  State<PictureCalendar> createState() => _PictureCalendarState();
}

class _PictureCalendarState extends State<PictureCalendar> {
  late DateTime _focusMonth;
  late Map<String, BodyPicture> _byDay;

  @override
  void initState() {
    super.initState();
    _buildIndex();
    // Start at the month of the most recent picture, or today
    if (widget.pictures.isNotEmpty) {
      final latest = DateTime.parse(widget.pictures.first.pictureDate);
      _focusMonth = DateTime(latest.year, latest.month);
    } else {
      final now = DateTime.now();
      _focusMonth = DateTime(now.year, now.month);
    }
  }

  void _buildIndex() {
    _byDay = {};
    for (final p in widget.pictures) {
      _byDay[p.pictureDate] = p;
    }
  }

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _monthLabel(DateTime m) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${months[m.month - 1]} ${m.year}';
  }

  void _prevMonth() => setState(
    () => _focusMonth = DateTime(_focusMonth.year, _focusMonth.month - 1),
  );

  void _nextMonth() => setState(
    () => _focusMonth = DateTime(_focusMonth.year, _focusMonth.month + 1),
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final firstDay = DateTime(_focusMonth.year, _focusMonth.month, 1);
    final lastDay = DateTime(_focusMonth.year, _focusMonth.month + 1, 0);
    final startWeekday = firstDay.weekday;
    final daysInMonth = lastDay.day;

    return Column(
      children: [
        // Month navigation
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _prevMonth,
              ),
              Text(
                _monthLabel(_focusMonth),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _nextMonth,
              ),
            ],
          ),
        ),
        // Day-of-week header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
                .map(
                  (d) => Expanded(
                    child: Center(
                      child: Text(
                        d,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 4),
        // Calendar grid
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.count(
            crossAxisCount: 7,
            childAspectRatio: 1.0,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: List.generate(startWeekday - 1 + daysInMonth, (i) {
              if (i < startWeekday - 1) {
                // Empty cell for days before month starts
                return const SizedBox();
              }
              final day = i - startWeekday + 2;
              final date = DateTime(_focusMonth.year, _focusMonth.month, day);
              final key = _dayKey(date);
              final picture = _byDay[key];
              final hasPicture = picture != null;

              return GestureDetector(
                onTap: hasPicture ? () => widget.onDayTap(picture) : null,
                child: Container(
                  decoration: BoxDecoration(
                    color: hasPicture
                        ? colorScheme.primary
                        : Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      day.toString(),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: hasPicture ? Colors.white : Colors.grey.shade600,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class PictureViewerDialog extends StatefulWidget {
  final BodyPicture picture;
  final List<BodyPicture> allPictures;
  final VoidCallback onDelete;

  const PictureViewerDialog({
    super.key,
    required this.picture,
    required this.allPictures,
    required this.onDelete,
  });

  @override
  State<PictureViewerDialog> createState() => _PictureViewerDialogState();
}

class _PictureViewerDialogState extends State<PictureViewerDialog> {
  late int _currentIndex;
  String? _imageData;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.allPictures.indexWhere(
      (p) => p.pictureDate == widget.picture.pictureDate,
    );
    if (_currentIndex == -1) _currentIndex = 0;
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final data = await api.getBodyPictureData(
        widget.allPictures[_currentIndex].pictureDate,
      );
      if (mounted) {
        setState(() {
          _imageData = data;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _previousPicture() {
    if (_currentIndex > 0) {
      setState(() => _currentIndex--);
      _loadImage();
    }
  }

  void _nextPicture() {
    if (_currentIndex < widget.allPictures.length - 1) {
      setState(() => _currentIndex++);
      _loadImage();
    }
  }

  Future<void> _deletePicture() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete picture?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await api.deleteBodyPicture(
        widget.allPictures[_currentIndex].pictureDate,
      );
      if (mounted) {
        Navigator.pop(context);
        widget.onDelete();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPicture = widget.allPictures[_currentIndex];
    final canPrev = _currentIndex > 0;
    final canNext = _currentIndex < widget.allPictures.length - 1;

    return Dialog(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with date and navigation
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  currentPicture.pictureDate,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          // Image viewer with swipe
          if (_loading)
            const SizedBox(
              height: 300,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SizedBox(
              height: 300,
              child: Center(
                child: Text(
                  'Error: $_error',
                  style: TextStyle(color: Colors.red.shade700),
                ),
              ),
            )
          else if (_imageData != null)
            GestureDetector(
              onHorizontalDragEnd: (details) {
                if (details.primaryVelocity! > 0 && canPrev) {
                  _previousPicture();
                } else if (details.primaryVelocity! < 0 && canNext) {
                  _nextPicture();
                }
              },
              child: Image.memory(
                base64Decode(_imageData!),
                height: 400,
                width: double.infinity,
                fit: BoxFit.contain,
              ),
            ),
          // Metadata
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Uploaded: ${currentPicture.createdAt}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
          // Navigation buttons
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: canPrev ? _previousPicture : null,
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '${_currentIndex + 1} / ${widget.allPictures.length}',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: canNext ? _nextPicture : null,
                ),
              ],
            ),
          ),
          // Delete button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _deletePicture,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade400,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
