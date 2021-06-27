DESTDIR=/usr/local

# install deven
install :
	if [[ -z "${BASH_OO}" ]]; then
		git clone https://github.com/niieani/bash-oo-framework.git ~/.bash-oo-framework
		echo "export BASH_OO=\$HOME/.bash-oo-framework/lib" >> ~/.bashrc
	fi
	mkdir -p ${HOME}/.config/.deven
	cp x11.profile ${HOME}/.config/.deven/
	sudo cp deven.sh ${DESTDIR}/bin/deven
	sudo chmod +x ${DESTDIR}/bin/deven

# uninstall deven
uninstall :
	rm -rf ${HOME}/.config/.deven/
	sudo rm ${DESTDIR}/bin/deven
	echo "\e[32mdeven has been uninstalled."
