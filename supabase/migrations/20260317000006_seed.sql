-- ============================================================
-- System category seed data (user_id = NULL)
-- ============================================================
INSERT INTO categories (user_id, name, icon, color, is_fixed_cost, sort_order) VALUES
  (NULL, '食費',       'fork.knife',           '#FF6B6B', false, 1),
  (NULL, 'コンビニ',    'building.2',           '#FFA07A', false, 2),
  (NULL, 'カフェ',      'cup.and.saucer',       '#D2B48C', false, 3),
  (NULL, '交通費',      'tram',                 '#4ECDC4', false, 4),
  (NULL, '日用品',      'cart',                 '#95E1D3', false, 5),
  (NULL, '衣服',       'tshirt',               '#DDA0DD', false, 6),
  (NULL, '娯楽',       'gamecontroller',       '#87CEEB', false, 7),
  (NULL, '医療',       'cross.case',           '#FF69B4', false, 8),
  (NULL, '通信費',      'wifi',                 '#778899', true,  9),
  (NULL, 'サブスク',    'repeat',               '#9370DB', true,  10),
  (NULL, '家賃',       'house',                '#CD853F', true,  11),
  (NULL, '光熱費',      'bolt',                 '#FFD700', true,  12),
  (NULL, '保険',       'shield',               '#2E8B57', true,  13),
  (NULL, '教育',       'book',                 '#6495ED', false, 14),
  (NULL, '美容',       'scissors',             '#FF69B4', false, 15),
  (NULL, '貯蓄・投資',  'banknote',             '#4CAF50', false, 16),
  (NULL, '振込・送金',  'arrow.right.arrow.left', '#607D8B', false, 17),
  (NULL, 'その他',      'ellipsis.circle',      '#A9A9A9', false, 99)
ON CONFLICT (user_id, name) DO NOTHING;
