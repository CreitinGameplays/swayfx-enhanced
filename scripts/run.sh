ASAN_OPTIONS=halt_on_error=1:abort_on_error=1:detect_leaks=0 \
./build-asan/sway/sway -d 2> /tmp/swayfx-asan.log
