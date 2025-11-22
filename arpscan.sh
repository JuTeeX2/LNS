#!/bin/bash

# Выходить при ошибках, использовать абсолютные пути
set -e

echo "Установка git wget"
sudo apt install git wget build-essential

echo "<=====================>"
# Создаем временную директорию и работаем в ней
WORKDIR=$(mktemp -d)
cd "$WORKDIR"

echo "Установка autoconf-2.71"
wget http://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.xz
tar -xf autoconf-2.71.tar.xz
cd autoconf-2.71
./configure
make
sudo make install

cd "$WORKDIR"

echo "Установка arp-scan"
git clone https://github.com/royhills/arp-scan.git
cd arp-scan
autoreconf --install
./configure
make
sudo make install

# Очистка
cd /
sudo rm -rf "$WORKDIR"
sudo rm -rf autoconf-2.71.tar
sudo rm -rf autoconf-2.71
sudo rm -rf arp-scan

echo "Установка завершена!"
