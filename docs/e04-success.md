# Чистая установка: успешный запуск

28 октября 2026 года выполнена команда `bash scripts/setup.sh --reset` в Git Bash. В этой сессии к `PATH` добавлен каталог уже установленного Docker Desktop: `C:\Users\happy\AppData\Local\Programs\DockerDesktop\resources\bin`. Скрипт выбрал `py -3`, установил `psycopg2-binary`, запустил PostgreSQL 16 и без ручной правки CSV загрузил `raw`.

Выдержка из вывода загрузчика и повторная проверка SQL:

| Таблица `raw` | Строк |
| --- | ---: |
| `orders` | 99 441 |
| `order_items` | 112 650 |
| `order_payments` | 103 886 |
| `order_reviews` | 99 224 |
| `products` | 32 951 |
| `sellers` | 3 095 |
| `customers` | 99 441 |
| `product_category_translation` | 71 |
| **Итого** | **550 759** |

После установки `setup.sh` показал три схемы: `raw` — 8 таблиц, `core` и `mart` — по 0 таблиц до запуска модели. Исходная неудачная попытка без Docker в `PATH` сохранена в [e04-setup-output.txt](e04-setup-output.txt).
