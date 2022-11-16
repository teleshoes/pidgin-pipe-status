set -x
cp pidgin-pipe-status.pl ~/.purple/plugins/
if [ ! -e ~/.purple/plugins/pidgin-pipe-status-config.properties ]; then
  cp pidgin-pipe-status-config.properties ~/.purple/plugins/
fi
