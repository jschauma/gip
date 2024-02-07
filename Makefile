NAME=gip
PREFIX?=/usr/local

help:
	@echo "The following targets are available:"
	@echo "clean    remove temporary files"
	@echo "install  install all files under ${PREFIX}"
	@echo "man      generate a formatted ascii man page"
	@echo "prep     update the perl path in the source script"
	@echo "readme   generate the README after a manual page update"

prep: src/${NAME}

src/${NAME}: src/${NAME}.pl
	sed -e "s|/usr/local/bin/perl|$$(which perl)|" $? >$@

install: prep
	mkdir -p ${PREFIX}/bin ${PREFIX}/share/man/man1
	install -m 755 src/${NAME} ${PREFIX}/bin/${NAME}
	install -m 444 doc/${NAME}.1 ${PREFIX}/share/man/man1

clean:
	rm -f src/${NAME}

man: doc/${NAME}.1.txt

doc/${NAME}.1.txt: doc/${NAME}.1
	groff -Tascii -mandoc $? | col -b >$@

readme: man
	sed -n -e '/^NAME/!p;//q' README.md >.readme
	sed -n -e '/^NAME/,$$p' -e '/emailing/q' doc/${NAME}.1.txt >>.readme
	echo '```' >>.readme
	mv .readme README.md
