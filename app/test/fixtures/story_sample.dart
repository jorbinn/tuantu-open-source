Map<String, dynamic> storySample({int photos = 18, int appear = 7}) => {
      'day': '2026-09-20',
      'offset': 480,
      'basis': 'capture',
      'generated_at': 1790000000,
      'identity': {'person_id': 1, 'name': '小雨'},
      'counts': {'photos': photos, 'videos': 2, 'audio': 0},
      'likes': 12,
      'comments': 3,
      'time_note': false,
      'members': [
        {'person_id': 1, 'name': '小雨', 'user_id': 11, 'photos': appear},
        {'person_id': 2, 'name': '阿宁', 'user_id': 12, 'photos': 5},
        {'person_id': 3, 'name': '小舟', 'user_id': 13, 'photos': 4},
      ],
      'pairs': [
        {'a': 1, 'b': 2, 'n': 3},
        {'a': 1, 'b': 3, 'n': 3}
      ],
      'uploaders': [
        {'user_id': 11, 'name': '小雨', 'photos': 6, 'videos': 1},
        {'user_id': 12, 'name': '阿宁', 'photos': 6, 'videos': 1},
        {'user_id': 13, 'name': '小舟', 'photos': 6, 'videos': 0},
      ],
      'pool': <Map<String, dynamic>>[],
      'person': {
        'person_id': 1,
        'user_id': 11,
        'photos': appear,
        'others_photos': 5,
        'partners': [
          {'person_id': 2, 'photos': 3},
          {'person_id': 3, 'photos': 3}
        ],
        'photographers': [
          {'user_id': 12, 'name': '阿宁', 'photos': 3},
          {'user_id': 13, 'name': '小舟', 'photos': 2},
          {'user_id': 11, 'name': '小雨', 'photos': 2}
        ],
      },
      'facts': {
        'my_uploads': 6,
        'my_videos': 1,
        'pending': 0,
        'time_fallback': 0,
        'my_likes': 5,
        'my_comments': 2
      },
    };
