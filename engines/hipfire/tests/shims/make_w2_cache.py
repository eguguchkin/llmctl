import sys
d = sys.argv[1]
with open(d + '/sub/tiny.bin', 'wb') as f:
    f.write(b'x' * 10)                 # рекурсия в подкаталог
with open(d + '/sparse.bin', 'wb') as f:
    f.truncate(3435973837)             # st_size = 3.2 GiB без записи блоков
