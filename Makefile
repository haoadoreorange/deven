DESTDIR=/usr/local

# install deven
install :
	mkdir -p /home/${SUDO_USER}/.deven
	cp x11.profile /home/${SUDO_USER}/.deven/
	cp deven.sh ${DESTDIR}/bin/deven
	chmod +x ${DESTDIR}/bin/deven

# uninstall deven
uninstall :
	rm -rf /home/${SUDO_USER}/.deven
	rm "${DESTDIR}/bin/deven"
	echo "\e[32mdeven has been uninstalled."
