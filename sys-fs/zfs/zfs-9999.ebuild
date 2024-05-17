# Copyright 1999-2024 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DISTUTILS_OPTIONAL=1
DISTUTILS_USE_PEP517=setuptools
PYTHON_COMPAT=( python3_{10..12} )

MODULES_INITRAMFS_IUSE=+initramfs
MODULES_OPTIONAL_IUSE=+modules

inherit autotools bash-completion-r1 distutils-r1 flag-o-matic
inherit linux-mod-r1 multiprocessing pam systemd udev usr-ldscript

DESCRIPTION="Userland utilities for ZFS Linux kernel module"
HOMEPAGE="https://github.com/openzfs/zfs"

MODULES_KERNEL_MAX=6.8
MODULES_KERNEL_MIN=3.10

if [[ ${PV} == "9999" ]]; then
	inherit git-r3
	EGIT_REPO_URI="https://github.com/openzfs/zfs.git"
else
	VERIFY_SIG_OPENPGP_KEY_PATH=/usr/share/openpgp-keys/openzfs.asc
	inherit verify-sig

	MY_P="${P/_rc/-rc}"
	SRC_URI="https://github.com/openzfs/${PN}/releases/download/${MY_P}/${MY_P}.tar.gz"
	SRC_URI+=" verify-sig? ( https://github.com/openzfs/${PN}/releases/download/${MY_P}/${MY_P}.tar.gz.asc )"
	S="${WORKDIR}/${MY_P}"

	ZFS_KERNEL_COMPAT="${MODULES_KERNEL_MAX}"
	# Increments minor eg 5.14 -> 5.15, and still supports override.
	ZFS_KERNEL_DEP="${ZFS_KERNEL_COMPAT_OVERRIDE:-${ZFS_KERNEL_COMPAT}}"
	ZFS_KERNEL_DEP="${ZFS_KERNEL_DEP%%.*}.$(( ${ZFS_KERNEL_DEP##*.} + 1))"

	if [[ ${PV} != *_rc* ]]; then
		KEYWORDS="~amd64 ~arm64 ~loong ~ppc64 ~riscv ~sparc"
	fi
fi

LICENSE="BSD-2 CDDL MIT modules? ( debug? ( GPL-2+ ) )"
# just libzfs soname major for now.
# possible candidates: libuutil, libzpool, libnvpair. Those do not provide stable abi, but are considered.
# see libsoversion_check() below as well
SLOT="0/5"
IUSE="custom-cflags debug minimal nls pam python +rootfs selinux test-suite"

DEPEND="
	dev-libs/openssl:=
	net-libs/libtirpc:=
	sys-apps/util-linux
	sys-libs/zlib
	virtual/libudev:=
	!minimal? ( ${PYTHON_DEPS} )
	pam? ( sys-libs/pam )
	python? (
		$(python_gen_cond_dep 'dev-python/cffi[${PYTHON_USEDEP}]' 'python*')
	)
"

BDEPEND="
	app-alternatives/awk
	virtual/pkgconfig
	modules? ( dev-lang/perl )
	nls? ( sys-devel/gettext )
	python? (
		${DISTUTILS_DEPS}
		|| (
			dev-python/packaging[${PYTHON_USEDEP}]
			dev-python/distlib[${PYTHON_USEDEP}]
		)
	)
"

if [[ ${PV} != "9999" ]] ; then
	BDEPEND+=" verify-sig? ( sec-keys/openpgp-keys-openzfs )"

	IUSE+=" +dist-kernel-cap"
	RDEPEND="
		dist-kernel-cap? ( dist-kernel? (
			<virtual/dist-kernel-${ZFS_KERNEL_DEP}
		) )
	"
fi

# awk is used for some scripts, completions, and the Dracut module
RDEPEND="
	${DEPEND}
	!prefix? ( virtual/udev )
	app-alternatives/awk
	sys-fs/udev-init-scripts
	dist-kernel? ( virtual/dist-kernel:= )
	rootfs? (
		app-alternatives/cpio
		app-misc/pax-utils
	)
	selinux? ( sec-policy/selinux-zfs )
	test-suite? (
		app-shells/ksh
		sys-apps/kmod[tools]
		sys-apps/util-linux
		app-alternatives/bc
		sys-block/parted
		sys-fs/lsscsi
		sys-fs/mdadm
		sys-process/procps
	)
	!sys-fs/zfs-kmod
"

REQUIRED_USE="
	!minimal? ( ${PYTHON_REQUIRED_USE} )
	python? ( !minimal )
	test-suite? ( !minimal )
"

RESTRICT="test"

PATCHES=(
	"${FILESDIR}"/2.1.5-dracut-zfs-missing.patch
	"${FILESDIR}"/${PN}-2.1.11-gentoo.patch
)

DOCS=(
	AUTHORS COPYRIGHT META README.md
)

pkg_pretend() {
	use rootfs || return 0

	if has_version virtual/dist-kernel && ! use dist-kernel; then
		ewarn "You have virtual/dist-kernel installed, but"
		ewarn "USE=\"dist-kernel\" is not enabled for ${CATEGORY}/${PN}"
		ewarn "It's recommended to globally enable dist-kernel USE flag"
		ewarn "to auto-trigger initrd rebuilds with kernel updates"
	fi
}

pkg_setup() {
	if use kernel_linux; then
		if use modules; then
			local CONFIG_CHECK="
				EFI_PARTITION
				ZLIB_DEFLATE
				ZLIB_INFLATE
				!DEBUG_LOCK_ALLOC
				!PAX_KERNEXEC_PLUGIN_METHOD_OR
			"
			use debug && CONFIG_CHECK+="
				DEBUG_INFO
				FRAME_POINTER
				!DEBUG_INFO_REDUCED
			"
			use rootfs && CONFIG_CHECK+="
				BLK_DEV_INITRD
				DEVTMPFS
			"

			kernel_is -lt 5 && CONFIG_CHECK+=" IOSCHED_NOOP"

			if [[ ${PV} != 9999 ]] ; then
				local kv_major_max kv_minor_max zcompat
				zcompat="${ZFS_KERNEL_COMPAT_OVERRIDE:-${ZFS_KERNEL_COMPAT}}"
				kv_major_max="${zcompat%%.*}"
				zcompat="${zcompat#*.}"
				kv_minor_max="${zcompat%%.*}"
				kernel_is -le "${kv_major_max}" "${kv_minor_max}" || die \
					"Linux ${kv_major_max}.${kv_minor_max} is the latest supported version"
			fi

			linux-mod-r1_pkg_setup
		else
			linux-info_pkg_setup
		fi

		if ! linux_config_exists; then
			ewarn "Cannot check the linux kernel configuration."
		else
			if use test-suite; then
				if linux_chkconfig_present BLK_DEV_LOOP; then
					eerror "The ZFS test suite requires loop device support enabled."
					eerror "Please enable it:"
					eerror "    CONFIG_BLK_DEV_LOOP=y"
					eerror "in /usr/src/linux/.config or"
					eerror "    Device Drivers --->"
					eerror "        Block devices --->"
					eerror "            [X] Loopback device support"
				fi
			fi
		fi
	fi
}

libsoversion_check() {
	local bugurl libzfs_sover
	bugurl="https://bugs.gentoo.org/enter_bug.cgi?form_name=enter_bug&product=Gentoo+Linux&component=Current+packages"

	libzfs_sover="$(grep 'libzfs_la_LDFLAGS += -version-info' lib/libzfs/Makefile.am \
		| grep -Eo '[0-9]+:[0-9]+:[0-9]+')"
	libzfs_sover="${libzfs_sover%%:*}"

	if [[ ${libzfs_sover} -ne $(ver_cut 2 ${SLOT}) ]]; then
		echo
		eerror "BUG BUG BUG BUG BUG BUG BUG BUG"
		eerror "ebuild subslot does not match libzfs soversion!"
		eerror "libzfs soversion: ${libzfs_sover}"
		eerror "ebuild value: $(ver_cut 2 ${SLOT})"
		eerror "This is a bug in the ebuild, please use the following URL to report it"
		eerror "${bugurl}&short_desc=${CATEGORY}%2F${P}+update+subslot"
		echo
		# we want to abort for releases, but just print a warning for live ebuild
		# to keep package installable
		[[  ${PV} == "9999" ]] || die
	fi
}

src_prepare() {
	default
	libsoversion_check

	# Run unconditionally (bug #792627)
	eautoreconf

	if [[ ${PV} != "9999" ]]; then
		# Set revision number
		sed -i "s/\(Release:\)\(.*\)1/\1\2${PR}-gentoo/" META || die "Could not set Gentoo release"
	fi

	if use python; then
		pushd contrib/pyzfs >/dev/null || die
		distutils-r1_src_prepare
		popd >/dev/null || die
	fi

	# Tries to use /etc/conf.d which we reserve for OpenRC
	sed -i -e '/EnvironmentFile/d' etc/systemd/system/zfs*.in || die

	# prevent errors showing up on zfs-mount stop, #647688
	# openrc will unmount all filesystems anyway.
	sed -i "/^ZFS_UNMOUNT=/ s/yes/no/" "etc/default/zfs.in" || die
}

src_configure() {
	use custom-cflags || strip-flags
	use minimal || python_setup

	local myconf=(
		--bindir="${EPREFIX}/bin"
		--sbindir="${EPREFIX}/sbin"
		--enable-shared
		--enable-sysvinit
		--localstatedir="${EPREFIX}/var"
		--sbindir="${EPREFIX}/sbin"
		--with-config="$(usex modules all user)"
		--with-dracutdir="${EPREFIX}/usr/lib/dracut"
		--with-linux="${KV_DIR}"
		--with-linux-obj="${KV_OUT_DIR}"
		--with-udevdir="$(get_udevdir)"
		--with-pamconfigsdir="${EPREFIX}/unwanted_files"
		--with-pammoduledir="$(getpam_mod_dir)"
		--with-systemdunitdir="$(systemd_get_systemunitdir)"
		--with-systemdpresetdir="$(systemd_get_systempresetdir)"
		--with-vendor=gentoo
		# Building zfs-mount-generator.c on musl breaks as strndupa
		# isn't available. But systemd doesn't support musl anyway, so
		# just disable building it.
		# UPDATE: it has been fixed since,
		# https://github.com/openzfs/zfs/commit/1f19826c9ac85835cbde61a7439d9d1fefe43a4a
		# but we still leave it as this for now.
		$(use_enable !elibc_musl systemd)
		$(use_enable debug)
		$(use_enable nls)
		$(use_enable pam)
		$(use_enable python pyzfs)
		--disable-static
		$(usex minimal --without-python --with-python="${EPYTHON}")

		# See gentoo.patch
		GENTOO_MAKEARGS_EVAL="${MODULES_MAKEARGS[*]@Q}"
		TEST_JOBS="$(makeopts_jobs)"
	)

	econf "${myconf[@]}"
}

src_compile() {
	if use modules; then
		emake "${MODULES_MAKEARGS[@]}"
	else
		default
	fi

	if use python; then
		pushd contrib/pyzfs >/dev/null || die
		distutils-r1_src_compile
		popd >/dev/null || die
	fi
}

src_install() {
	if use modules; then
		emake "${MODULES_MAKEARGS[@]}" DESTDIR="${ED}" install
		modules_post_process
	else
		default
	fi

	gen_usr_ldscript -a nvpair uutil zfsbootenv zfs zfs_core zpool

	use pam && { rm -rv "${ED}/unwanted_files" || die ; }

	use test-suite || { rm -r "${ED}"/usr/share/zfs/{test-runner,zfs-tests,runfiles,*sh} || die ; }

	find "${ED}" -name '*.la' -delete || die

	dobashcomp contrib/bash_completion.d/zfs
	bashcomp_alias zfs zpool

	# strip executable bit from conf.d file
	fperms 0644 /etc/conf.d/zfs

	if use python; then
		pushd contrib/pyzfs >/dev/null || die
		distutils-r1_src_install
		popd >/dev/null || die
	fi

	# enforce best available python implementation
	use minimal || python_fix_shebang "${ED}/bin"
}

_old_layout_cleanup() {
	# new files are just extra/{spl,zfs}.ko with no subdirs.
	local olddir=(
		avl/zavl
		icp/icp
		lua/zlua
		nvpair/znvpair
		spl/spl
		unicode/zunicode
		zcommon/zcommon
		zfs/zfs
		zstd/zzstd
	)

	# kernel/module/Kconfig contains possible compressed extentions.
	local kext kextfiles
		for kext in .ko{,.{gz,xz,zst}}; do
		kextfiles+=( "${olddir[@]/%/${kext}}" )
	done

	local oldfile oldpath
	for oldfile in "${kextfiles[@]}"; do
		oldpath="${EROOT}/lib/modules/${KV_FULL}/extra/${oldfile}"
		if [[ -f "${oldpath}" ]]; then
			ewarn "Found obsolete zfs module ${oldfile} for current kernel ${KV_FULL}, removing."
			rm -rv "${oldpath}" || die
			# we do not remove non-empty directories just for safety in case there's something else.
			# also it may fail if there are both compressed and uncompressed modules installed.
			rmdir -v --ignore-fail-on-non-empty "${oldpath%/*.*}" || die
		fi
	done
}

pkg_postinst() {
	udev_reload

	if use modules; then
		# Check for old module layout before doing anything else.
		# only attempt layout cleanup if new .ko location is used.
		local newko=( "${EROOT}/lib/modules/${KV_FULL}/extra"/{zfs,spl}.ko* )
		# We check first array member, if glob above did not exand, it will be "zfs.ko*" and -f will return false.
		# if glob expanded -f will do correct file precense check.
		[[ -f ${newko[0]} ]] && _old_layout_cleanup

		linux-mod-r1_pkg_postinst

		if use x86 || use arm ; then
			ewarn "32-bit kernels will likely require increasing vmalloc to"
			ewarn "at least 256M and decreasing zfs_arc_max to some value less than that."
		fi

		if has_version sys-boot/grub ; then
			ewarn "This version of OpenZFS includes support for new feature flags"
			ewarn "that are incompatible with previous versions. GRUB2 support for"
			ewarn "/boot with the new feature flags is not yet available."
			ewarn "Do *NOT* upgrade root pools to use the new feature flags."
			ewarn "Any new pools will be created with the new feature flags by default"
			ewarn "and will not be compatible with older versions of OpenZFS. To"
			ewarn "create a new pool that is backward compatible wih GRUB2, use "
			ewarn
			ewarn "zpool create -o compatibility=grub2 ..."
			ewarn
			ewarn "Refer to /usr/share/zfs/compatibility.d/grub2 for list of features."
		fi
	fi

	if use rootfs; then
		if ! has_version sys-kernel/genkernel && ! has_version sys-kernel/dracut; then
			elog "Root on zfs requires an initramfs to boot"
			elog "The following packages provide one and are tested on a regular basis:"
			elog "  sys-kernel/dracut ( preferred, module maintained by zfs developers )"
			elog "  sys-kernel/genkernel"
		fi
	fi

	if systemd_is_booted || has_version sys-apps/systemd; then
		einfo "Please refer to ${EROOT}/$(systemd_get_systempresetdir)/50-zfs.preset"
		einfo "for default zfs systemd service configuration"
	else
		[[ -e "${EROOT}/etc/runlevels/boot/zfs-import" ]] || \
			einfo "You should add zfs-import to the boot runlevel."
		[[ -e "${EROOT}/etc/runlevels/boot/zfs-load-key" ]] || \
			einfo "You should add zfs-load-key to the boot runlevel."
		[[ -e "${EROOT}/etc/runlevels/boot/zfs-mount" ]]|| \
			einfo "You should add zfs-mount to the boot runlevel."
		[[ -e "${EROOT}/etc/runlevels/default/zfs-share" ]] || \
			einfo "You should add zfs-share to the default runlevel."
		[[ -e "${EROOT}/etc/runlevels/default/zfs-zed" ]] || \
			einfo "You should add zfs-zed to the default runlevel."
	fi
}

pkg_postrm() {
	udev_reload
}
