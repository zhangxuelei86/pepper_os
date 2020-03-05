FROM awesomebytes/pepper_2.5.5.5

USER nao
WORKDIR /home/nao

RUN cat /proc/cpuinfo; cat /proc/meminfo; df -h

# Download and extract the latest Gentoo Prefix + ROS desktop image
RUN last_desktop_url=`curl -s -L https://github.com/awesomebytes/ros_overlay_on_gentoo_prefix_32b/releases | grep -m 1 "ROS Melodic desktop" | cut -d '"' -f2 | xargs -n 1 printf "http://github.com%s\n"`; \
curl -s -L $last_desktop_url | grep download/release | cut -d '"' -f2 | xargs -n 1 printf "https://github.com%s\n" | xargs -n 1 curl -O -L -s &&\
    cat gentoo_on_tmp* > gentoo_on_tmp.tar.gz &&\
    rm gentoo_on_tmp*.part* &&\
    tar xf gentoo_on_tmp.tar.gz &&\
    rm gentoo_on_tmp.tar.gz

# Fix permissions of tmp
USER root
RUN chmod a=rwx,o+t /tmp
USER nao


# Prepare environment to run everything in the prefixed shell
RUN cd /tmp && ln -s /home/nao/gentoo gentoo &&\
    cp /etc/group /tmp/gentoo/etc/group || true &&\
    cp /etc/passwd /tmp/gentoo/etc/passwd || true
# To make sure everything builds and reports i686 we do this trick
RUN sed -i 's/env -i/linux32 env -i/' /tmp/gentoo/executeonprefix
# To allow the use of the $EPREFIX variable
RUN sed -i 's/SHELL=$SHELL"/SHELL=$SHELL EPREFIX=$EPREFIX"/' /tmp/gentoo/executeonprefix
# Note that no variables exposed from this Dockerfile will work on the
# RUN commands as they will be evaluated by the internal executeonprefix script

# And now switch the shell so every RUN command is executed in it
SHELL ["/tmp/gentoo/executeonprefix"]

# Let's make the compilations faster when possible
# Substitute the default -j2 with -j<NUM_CORES/2>
RUN sed -i -e 's/j1/j'"$((`grep -c \^processor \/proc\/cpuinfo` / 2))"'/g' $EPREFIX/etc/portage/make.conf
# Add extra jobs if we have enough CPUs
RUN sed -i 's/EMERGE_DEFAULT_OPTS=.*//' $EPREFIX/etc/portage/make.conf &&\
    echo "EMERGE_DEFAULT_OPTS=\"--jobs $((`grep -c \^processor \/proc\/cpuinfo` / 2)) --load-average `grep -c \^processor \/proc\/cpuinfo`\"" >> $EPREFIX/etc/portage/make.conf

# Force CHOST to build everything or 32b
RUN echo "CHOST=i686-pc-linux-gnu" >> $EPREFIX/etc/portage/make.conf

# Update our source repos first
# Because we may have previous patches that won't allow to do a sync...
RUN cd $EPREFIX/usr/local/portage && git reset --hard
# Now we can update
RUN emaint sync -a
# Prepare python
RUN emerge dev-python/pip
RUN pip install --user argparse

RUN echo "# required by ros-melodic/pcl_conversions-0.2.1::ros-overlay for navigation" >> $EPREFIX/etc/portage/package.accept_keywords &&\
    echo "=sci-libs/pcl-9999 **" >> $EPREFIX/etc/portage/package.accept_keywords

# Very ugly hack, need to fix this from whereve it came
# some packages are affected, others arent, weird
RUN cd /tmp/gentoo/opt &&\
    find ./ -type f -name *.pc -exec sed -i -e 's@/home/user/gentoo@/tmp/gentoo@g' {} \; &&\
    find ./ -type f -name *.cmake -exec sed -i -e 's@/home/user/gentoo@/tmp/gentoo@g' {} \;


RUN cd /tmp && git clone https://github.com/awesomebytes/pepper_os &&\
    mkdir -p /tmp/gentoo/etc/portage/patches/ros-melodic &&\
    cp -r pepper_os/patches/* /tmp/gentoo/etc/portage/patches/ros-melodic &&\
    rm -rf pepper_os

# Navigation needs it becuase of ros-melodic/move_slow_and_clear
# Giving error: 
# RUN mkdir -p /tmp/gentoo/etc/portage/patches/sci-libs/pcl-1.8.1 && \
#     cd /tmp/gentoo/etc/portage/patches/sci-libs/pcl-1.8.1 && \
#     wget https://664126.bugs.gentoo.org/attachment.cgi?id=545428 -O gcc8.patch
RUN echo ">=sci-libs/pcl-1.10.0" >> /tmp/gentoo/etc/portage/package.mask
RUN echo "=sci-libs/pcl-1.9.1 **" >> /tmp/gentoo/etc/portage/package.accept_keywords
RUN emerge sci-libs/pcl

RUN emerge ros-melodic/robot_state_publisher \
    ros-melodic/geometry2 \
    ros-melodic/ros_control
RUN emerge ros-melodic/image_common \
    ros-melodic/image_transport_plugins \
    ros-melodic/diagnostics \
    ros-melodic/octomap_msgs \
    ros-melodic/tf2_geometry_msgs \
    ros-melodic/ros_numpy \
    ros-melodic/ddynamic_reconfigure_python


RUN emerge ros-melodic/navigation
RUN emerge ros-melodic/slam_gmapping
RUN emerge ros-melodic/depthimage_to_laserscan
RUN emerge ros-melodic/rosbridge_suite
RUN emerge ros-melodic/cmake_modules \
    ros-melodic/naoqi_bridge_msgs \
    ros-melodic/perception_pcl \
    ros-melodic/pcl_conversions \
    ros-melodic/pcl_ros
RUN emerge media-libs/portaudio \
    net-libs/libnsl \
    dev-cpp/eigen

RUN emerge media-libs/opus

# emerging pulseaudio asks for this
RUN echo ">=media-plugins/alsa-plugins-1.2.1 pulseaudio" >> $EPREFIX/etc/portage/package.use
# To avoid:
#  * Error: circular dependencies:
# (sys-libs/pam-1.3.1-r1:0/0::gentoo, ebuild scheduled for merge) depends on
#  (sys-libs/libcap-2.27:0/0::gentoo, ebuild scheduled for merge) (buildtime)
#   (sys-libs/pam-1.3.1-r1:0/0::gentoo, ebuild scheduled for merge) (buildtime)
RUN echo ">=sys-libs/libcap-2.27 -pam" >> $EPREFIX/etc/portage/package.use
# Until https://bugs.gentoo.org/702566 it's solved
RUN echo ">=sys-libs/libcap-2.28" >> $EPREFIX/etc/portage/package.mask
RUN echo "media-sound/pulseaudio -udev" >> $EPREFIX/etc/portage/package.use
RUN emerge media-sound/pulseaudio


RUN echo ">=ros-melodic/mbf_simple_nav-0.2.5-r1 3-Clause" >> $EPREFIX/etc/portage/package.license
RUN echo ">=ros-melodic/mbf_costmap_nav-0.2.5-r1 3-Clause" >> $EPREFIX/etc/portage/package.license
RUN echo ">=ros-melodic/mbf_msgs-0.2.5-r1 3-Clause" >> $EPREFIX/etc/portage/package.license
RUN echo ">=ros-melodic/mbf_abstract_nav-0.2.5-r1 3-Clause" >> $EPREFIX/etc/portage/package.license
RUN emerge ros-melodic/move_base_flex

# #     ros-melodic/naoqi_libqicore \
# #     ros-melodic/naoqi_libqi \
# # need the patches I made in ros_pepperfix

# #     ros-melodic/web_video_server \
# # CODEC_FLAG_GLOBAL_HEADER -> AV_CODEC_FLAG_GLOBAL_HEADER

# RUN pip install --user dlib
# As Pepper CPU has no AVX instructions
RUN git clone https://github.com/davisking/dlib &&\
    cd dlib &&\
    pip uninstall dlib -y &&\
    python setup.py install --user --no USE_AVX_INSTRUCTIONS

RUN pip install --user pysqlite
RUN pip install --user ipython
RUN pip install --user --upgrade numpy
RUN pip install --user scipy pytz wstool
# RUN pip install --user pytz
# RUN pip install --user wstool

RUN pip install --user Theano
RUN pip install --user keras
RUN mkdir -p ~/.keras && \
echo '\
{\
    "image_data_format": "channels_last",\
    "epsilon": 1e-07,\
    "floatx": "float32",\
    "backend": "theano"\
}' > ~/.keras/keras.json


# # Tensorflow pending from our custom compiled one...
# # Which would be nice to automate too

RUN pip install --user h5py
RUN pip install --user opencv-python opencv-contrib-python

RUN pip install --user pyaudio

RUN pip install --user SpeechRecognition
RUN pip install --user nltk
RUN pip install --user pydub

RUN pip install --user jupyter

RUN pip install --user https://github.com/awesomebytes/pepper_os/releases/download/upload_tensorflow-1.6.0/tensorflow-1.6.0-cp27-cp27mu-linux_i686.whl

RUN pip install --user xxhash

RUN pip install --user catkin_tools

RUN emerge ros-melodic/eband_local_planner

# FOR ROS MELODIC SOME MODIFICATION OF THIS WILL MOST PROBABLY BE NEEDED
# AT LEAST THE HARDCODING OF BLAS LIBRARY FOUND
# RUN cd /tmp/gentoo/usr/local/portage/ros-melodic/libg2o &&\
#     rm * &&\
#     wget https://raw.githubusercontent.com/ros/ros-overlay/b76f702b1acfa384f0c43679a1fe67ab4c1f99fe/ros-melodic/libg2o/libg2o-2016.4.24.ebuild &&\
#     wget https://raw.githubusercontent.com/ros/ros-overlay/b76f702b1acfa384f0c43679a1fe67ab4c1f99fe/ros-melodic/libg2o/metadata.xml &&\
#     ebuild libg2o-2016.4.24.ebuild manifest
# # # undocumented dependency of teb_local_planner
# RUN emerge sci-libs/suitesparse
# RUN cd /tmp/gentoo/etc/portage/patches/ros-melodic &&\
#     mkdir -p libg2o-2016.4.24 &&\
#     cd libg2o-2016.4.24 &&\
#     wget https://gist.githubusercontent.com/awesomebytes/97aad67cbc86deb93a76ace964241848/raw/bc83232c2ff5df872db0d3d46d49aca1a78ecbc7/001-Debug-cholmod.patch &&\
#     wget https://gist.githubusercontent.com/awesomebytes/79bafc394be8389d6430393edf77be47/raw/faae7ba38692d05c841b0aa3495e1618a3a70ca0/002-Hardcode-BLAS.patch

RUN emerge sci-libs/cholmod
RUN cd /tmp/gentoo/usr/lib/cmake/Qt5Gui; find ./ -type f -exec sed -i -e 's@/home/user@/tmp@g' {} \;
RUN emerge ros-melodic/libg2o

# FOR MELODIC SOME PATCH WILL NEEDED TO BE DONE TOO, AS THERE ARE HARDCODED PATHS NOT INCLUDING PREFIX ONES
# RUN cd /tmp/gentoo/etc/portage/patches/ros-melodic &&\
#     mkdir -p teb_local_planner &&\
#     cd teb_local_planner &&\
#     wget https://gist.githubusercontent.com/awesomebytes/0e84ce3539cdbe6d8013a75f17de34a1/raw/c72c8d4f7d307e553629f18dab1c11d184e5295d/0001-Adapt-for-Gentoo-Prefix-on-tmp-gentoo.patch

RUN emerge ros-melodic/teb_local_planner
RUN emerge ros-melodic/dwa_local_planner
# Workaround
RUN cd /tmp/gentoo/usr/local/portage/ros-melodic/sbpl_lattice_planner &&\
    rm Manifest && \
    ebuild sbpl*.ebuild manifest
RUN emerge ros-melodic/sbpl_lattice_planner

# Meanwhile https://bugs.gentoo.org/705974 gets fixed upstream (make has a backward incompatible change)
RUN mkdir -p $EPREFIX/etc/portage/patches/media-libs/gstreamer-1.14.5 &&\
    wget https://705974.bugs.gentoo.org/attachment.cgi?id=604218 -O $EPREFIX/etc/portage/patches/media-libs/gstreamer-1.14.5/make-fix.patch
RUN mkdir -p $EPREFIX/etc/portage/patches/media-libs/gst-plugins-bad-1.14.5 &&\
    wget https://705974.bugs.gentoo.org/attachment.cgi?id=604222 -O $EPREFIX/etc/portage/patches/media-libs/gst-plugins-bad-1.14.5/make-fix.patch
RUN mkdir -p $EPREFIX/etc/portage/patches/media-libs/gst-plugins-base-1.14.5 &&\
    wget https://705974.bugs.gentoo.org/attachment.cgi?id=604220 -O $EPREFIX/etc/portage/patches/media-libs/gst-plugins-base-1.14.5/make-fix.patch


RUN EXTRA_ECONF="--enable-pulse" emerge media-libs/gst-plugins-good
RUN emerge media-plugins/gst-plugins-opus \
    media-plugins/gst-plugins-v4l2 \
    media-plugins/gst-plugins-jpeg \
    media-plugins/gst-plugins-libpng \
    media-plugins/gst-plugins-lame
RUN emerge media-plugins/gst-plugins-x264 media-plugins/gst-plugins-x265

RUN cd /tmp/gentoo/usr/local/portage/ros-melodic/gscam &&\
    wget  https://raw.githubusercontent.com/ros/ros-overlay/80a3d06744df220fadb34b638d94d4336af2b720/ros-melodic/gscam/Manifest&&\
    mkdir files && cd files &&\
    wget https://raw.githubusercontent.com/ros/ros-overlay/80a3d06744df220fadb34b638d94d4336af2b720/ros-melodic/gscam/files/0001-Prefer-Gstreamer-1.0-over-0.10.patch &&\
    wget https://raw.githubusercontent.com/ros/ros-overlay/80a3d06744df220fadb34b638d94d4336af2b720/ros-melodic/gscam/files/Add-CMAKE-flag-to-compile-with-Gstreamer-version-1.x.patch &&\
    cd .. && wget https://raw.githubusercontent.com/ros/ros-overlay/80a3d06744df220fadb34b638d94d4336af2b720/ros-melodic/gscam/gscam-1.0.1.ebuild &&\
    ebuild gscam-1.0.1.ebuild manifest
RUN emerge ros-melodic/gscam

# Install in our locally known path pynaoqi (to avoid sourcing /opt/aldebaran/lib/python2.7...)
RUN wget https://github.com/awesomebytes/pepper_os/releases/download/pynaoqi-python2.7-2.5.5.5-linux32/pynaoqi-python2.7-2.5.5.5-linux32.tar.gz &&\
    mkdir -p /home/nao/.local &&\
    cd /home/nao/.local &&\
    tar xvf /home/nao/pynaoqi-python2.7-2.5.5.5-linux32.tar.gz &&\
    rm /home/nao/pynaoqi-python2.7-2.5.5.5-linux32.tar.gz

# RUN cd /tmp/gentoo/usr/local/portage/ros-melodic/naoqi_libqicore &&\
#     rm Manifest && \
#     ebuild naoqi*.ebuild manifest

# TODO: Fix naoqi_libqi with boost 1.71
# RUN emerge ros-melodic/naoqi_libqi ros-melodic/naoqi_libqicore

# TODO: this errors... shouldn't be too bad
# RUN emerge ros-melodic/pepper_meshes

RUN emerge dev-libs/libusb

RUN pip install --user dill cloudpickle
RUN pip install --user uptime

RUN emerge ros-melodic/humanoid_nav_msgs
RUN emerge ros-melodic/rgbd_launch

# Fix all python shebangs
RUN cd ~/.local/bin &&\
    find ./ -type f -exec sed -i -e 's/\#\!\/usr\/bin\/python2.7/\#\!\/tmp\/gentoo\/usr\/bin\/python2.7/g' {} \;


# # Fix system stuff to not pull from .local python libs 
RUN echo -e "import sys\n\
if sys.executable.startswith('/usr/bin/python'):\n\
    sys.path = [p for p in sys.path if not p.startswith('/home/nao/.local')]" >> /home/nao/.local/lib/python2.7/site-packages/sitecustomize.py

# Enable pulseaudio if anyone manually executes startprefix
# Adding to the line 'RETAIN="HOME=$HOME TERM=$TERM USER=$USER SHELL=$SHELL"'
RUN sed 's/SHELL=$SHELL/SHELL=$SHELL XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR/g' /tmp/gentoo/startprefix_original

# Takes care of initializing the shell correctly
COPY --chown=nao:nao config/.bash_profile /home/nao/.bash_profile

# Takes care of booting roscore on boot
COPY --chown=nao:nao scripts/roscore_boot_manager.py /home/nao/.local/bin
COPY --chown=nao:nao scripts/run_roscore.sh /home/nao/.local/bin

# Run roscore on boot, executed by the robot on boot
RUN echo "/home/nao/.local/bin/roscore_boot_manager.py" >> /home/nao/naoqi/preferences/autoload.ini

# Fix new path on pynaoqi
RUN sed -i 's@/home/nao/pynaoqi-python2.7-2.5.5.5-linux32/lib/libqipython.so@/home/nao/.local/pynaoqi-python2.7-2.5.5.5-linux32/lib/libqipython.so@g' /home/nao/.local/pynaoqi-python2.7-2.5.5.5-linux32/lib/python2.7/site-packages/qi/__init__.py

RUN df -h
# TODO: https://github.com/uts-magic-lab/command_executer

ENTRYPOINT ["/tmp/gentoo/startprefix"]
