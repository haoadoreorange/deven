DESTDIR=/usr/local

# install deven
install :
	cp deven.sh ${DESTDIR}/bin/deven
	chmod +x ${DESTDIR}/bin/deven

# uninstall deven
uninstall :
	rm -rf "${DESTDIR}/bin/deven"
	echo "\e[32mdeven has been uninstalled."
