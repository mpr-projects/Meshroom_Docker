# Build Arguments (that are passed with --build-arg key=val)
# username=$USER
# (optional) njobs (defaults to 1)
# (optional) njobs_multiplier (defaults to 1)
# (optional) CPU_ARCHITECTURE (defaults to auto)
# (optional) ALICEVISION_COMMIT (defaults to 62ab2b5)
# (optional) MESHROOM_COMMIT (defaults to a0ef38d)
# (optional) QTALICEVISION_COMMIT (defaults to c40e186)

# each of AliceVision's dependencies is built with 'njobs' jobs and 
# 'njobs_multiplier' dependencies are built at the same time; as a result at
# most njobs_multiplier*njobs jobs will run at the same time

# CPU_ARCHITECTURE defaults to 'auto' but on my computers the architecture was not
# recognized correctly by default (that could be because we're running in docker);
# for best performance look at https://github.com/alicevision/AliceVision/blob/develop/src/cmake/OptimizeForArchitecture.cmake
# to find the name of your CPU architecture; if yours isn't there then just pick the
# latest predecessor that's available; for example, my laptop CPU is Tigerlake but
# that's not available so I picked cannonlake instead (which is a predecessor of
# tigerlake);

# this image installs CUDA 12.6, which should be compatible with CUDA drivers
# back to 525.60.13 (see https://docs.nvidia.com/deploy/cuda-compatibility/index.html
# for more details)

# to build use the command below; the final image has a size of 4.2G; during the
# build the build cache goes up to ~30G; you can specify where the build cache
# should be saved with the --cache-to flag:
#    docker buildx build -t debian12.6:Meshroom --build-arg username=$USER --build-arg njobs=8 --build-arg njobs_multiplier=3 --build-arg CPU_ARCHITECTURE=zen --no-cache .
# to clean the build cache run:
#    docker buildx prune
# to run Meshroom use the following command (and replace mpr with your username, you may have to change renderD129 to some other index):
#    docker run --rm -it --gpus all -e XDG_RUNTIME_DIR=/tmp -e WAYLAND_DISPLAY=$WAYLAND_DISPLAY -v $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY:/tmp/$WAYLAND_DISPLAY -e QT_QPA_PLATFORM=wayland --device=/dev/dri/renderD129 -v /home/mpr:/home/mpr debian12.6:Meshroom
# if you add your own nodes then you have to add the following to your 'docker run' command
#     -e MESHROOM_NODES_PATH=/path/to/nodes/folder

# When you first run Meshroom then you may want to remove 'root' from the shortcuts in Meshroom's file opener and add 'username' (from /home/username).


# download base package and update it
# -----------------------------------------------------------------------------
FROM debian:12.6 AS base
RUN apt update && apt upgrade -y


# install packages required for building applications (gfortran-12 is 
# required by lapack)
# -----------------------------------------------------------------------------
FROM base AS base_devel
RUN apt install -y git cmake build-essential \
				  autoconf libtool nasm automake gfortran-12


# add cuda repo
# -----------------------------------------------------------------------------
FROM base_devel AS base_devel_with_nvidia_repos
RUN apt install -y software-properties-common

WORKDIR /build_directory

ADD https://developer.download.nvidia.com/compute/cuda/12.6.1/local_installers/cuda-repo-debian12-12-6-local_12.6.1-560.35.03-1_amd64.deb .

RUN dpkg -i cuda-repo-debian12-12-6-local_12.6.1-560.35.03-1_amd64.deb && \
	cp /var/cuda-repo-debian12-12-6-local/cuda-*-keyring.gpg /usr/share/keyrings/ && \
	add-apt-repository contrib && \
	apt update


# install cuda toolkit and other packages required for building applications
# -----------------------------------------------------------------------------
FROM base_devel_with_nvidia_repos AS base_devel_with_cuda_toolkit
RUN apt -y install cuda-toolkit-12-6


# build AliceVision
# -----------------------------------------------------------------------------
FROM base_devel_with_cuda_toolkit AS build_av

# required by av dependencies
#   zlib1g-dev  # required by openexr
#   pkg-config  # ffmpeg complained about it missing sure if necessary)
#   liblz4-dev  # required by flann
#   libpcre2-dev libbison-dev  # required by SWIG
#   libxerces-c-dev  # required by E57Format
RUN apt install -y zlib1g-dev liblz4-dev libpcre2-dev libbison-dev \
				  libxerces-c-dev pkg-config

# dependencies of OpenImageIO, it compiles without them but I install them
# anyway to prevent poGIN_PATH="/opt/QtAtential issues when importing files types into Meshroom
# that I normally don't use (and therefore haven't tested)
RUN apt install -y libopenjp2-7-dev libopenvdb-dev libgif-dev libheif-dev \
				  libdcmtk-dev libfreetype-dev librust-bzip2-dev \
				  libopencolorio-dev libwebp-dev

# cmake doesn't find the fortran compiler by itself when building lapack
ENV FC=/usr/bin/gfortran-12

# cmake doesn't find the cuda compiler by itself when building ceres
ENV CUDACXX=/usr/local/cuda-12.6/bin/nvcc

WORKDIR /build_directory/AliceVision
RUN git clone https://github.com/alicevision/AliceVision.git --recursive

WORKDIR /build_directory/AliceVision/AliceVision
ARG ALICEVISION_COMMIT=62ab2b5
RUN git checkout ${ALICEVISION_COMMIT}
RUN git submodule update -i

# AliceVision uses CCTag v1.0.3 which want to compile for compute architectures
# 3.5 and 3.7, they are no longer supported in cuda 12.6; on newer systems like
# on Debian 12.6 there is an issue with taking the real part of eigenvalues;
# the results are inconsistent and usually give wrong results; I created a fork
# of CCTag v1.0.4 and added a patch for a quick fix; the patch below tells AV
# to use my fork instead of the official v1.0.3
COPY fix_cctag.patch /build_directory/AliceVision
RUN git apply -C1 ../fix_cctag.patch

# think there's an error in the code for main_importKnownPoses.cpp
COPY fix_importKnownPoses.patch /build_directory/AliceVision
RUN git apply -C1 ../fix_importKnownPoses.patch

# the build files are set up so that passing AV_BUILD_DEPENDENCIES_PARALLEL=x
# results in each dependency being built with x cores but not AliceVision
# itself, that's built with only one core; if instead we build with
# 'cmake --build . --parallel=y' then y dependencies are built at the same time
# (each with one core) and AliceVision is built with y cores; that is slow
# because some dependencies (e.g. suitesparse) are slow to compile and really
# benefit from mutliple cores; if we specify both then AliceVision is built
# with y cores but the y dependencies are built with x cores each; that's not
# what I want either; the patch changes the build files s.t. setting 
# AV_BUILD_DEPENDENCIES_PARALLEL=x builds both the dependencies and AliceVision
# with x cores (and --parallel=y is not used in the build command below)
COPY update_av_build_command.patch /build_directory/AliceVision
RUN git apply -C1 ../update_av_build_command.patch

WORKDIR /build_directory/AliceVision/build
ARG njobs=1
ARG CPU_ARCHITECTURE=auto
RUN cmake -DALICEVISION_BUILD_DEPENDENCIES=ON -DAV_BUILD_POPSIFT=OFF \
		 -DAV_USE_OPENMP=ON -DTARGET_ARCHITECTURE=${CPU_ARCHITECTURE} \
		 -DAV_BUILD_DEPENDENCIES_PARALLEL=${njobs} \
		 -DCMAKE_INSTALL_PREFIX=/usr/local -LH ../AliceVision

ARG njobs_multiplier=1
RUN cmake --build . --parallel ${njobs_multiplier}


# build QtAliceVision
# -----------------------------------------------------------------------------
FROM build_av AS build_qtav

RUN apt install -y qtbase5-dev qtdeclarative5-dev qt3d5-dev \
				  libqt5waylandclient5-dev libqt5charts5-dev

WORKDIR /build_directory/QtAliceVision
RUN git clone https://github.com/alicevision/QtAliceVision.git

WORKDIR /build_directory/QtAliceVision/QtAliceVision
ARG QTALICEVISION_COMMIT=c40e186
RUN git checkout ${QTALICEVISION_COMMIT}

WORKDIR /build_directory/QtAliceVision/build
RUN cmake -DCMAKE_INSTALL_PREFIX=/opt/QtAliceVision \
		 -DCMAKE_BUILD_TYPE=Release \
		 ../QtAliceVision

ARG njobs=1
RUN cmake --build . --parallel ${njobs}
RUN cmake --install . --prefix=/opt/QtAliceVision


# download or copy additional AliceVision data files (put into separate stage
# so changes in earlier layers don't require another download)
# -----------------------------------------------------------------------------
FROM base AS download_av_data

WORKDIR /AliceVisionData
ADD https://gitlab.com/alicevision/trainedVocabularyTreeData/raw/master/vlfeat_K80L3.SIFT.tree .
ADD https://gitlab.com/alicevision/SphereDetectionModel/-/raw/main/sphereDetection_Mask-RCNN.onnx .
ADD https://gitlab.com/alicevision/semanticSegmentationModel/-/raw/main/fcn_resnet50.onnx .


# build Python 3.10 (newer versions don't work with PySide2)
# -----------------------------------------------------------------------------
FROM base_devel AS build_python

RUN apt install -y libffi-dev liblzma-dev libsqlite3-dev libreadline-dev \
				  libncurses-dev zlib1g-dev libbz2-dev libssl-dev openssl

WORKDIR /build_directory
ADD https://www.python.org/ftp/python/3.10.13/Python-3.10.13.tgz .
RUN tar -xf Python-3.10.13.tgz

WORKDIR /build_directory/Python-3.10.13
RUN ./configure --enable-optimizations --prefix=/usr/local
ARG njobs=1
RUN make -j ${njobs}
RUN make install

# required by some of my custom nodes
RUN pip3 install numpy==1.26.4


# build cuda runtime for running the application
# -----------------------------------------------------------------------------
FROM base_devel_with_nvidia_repos AS base_devel_with_cuda_runtime
RUN apt install -y cuda-cudart-12-6 libcusolver-12-6 libcublas-12-6 \
				  libcusparse-12-6 libnvjitlink-12-6


# download Meshroom
# -----------------------------------------------------------------------------
FROM base_devel AS download_meshroom
WORKDIR /opt
RUN git clone --recursive https://github.com/alicevision/Meshroom.git

WORKDIR /opt/Meshroom
ARG MESHROOM_COMMIT=a0ef38d
RUN git checkout ${MESHROOM_COMMIT}  

COPY meshroom_gui_changes.patch ..
RUN git apply -C1 ../meshroom_gui_changes.patch


# final image used to run Meshroom
# -----------------------------------------------------------------------------
FROM base AS runtime

# first install runtime dependencies of packages which we'll copy from the
# build stages (Python, AliceVision and QtAliceVision dependencies)
RUN apt install -y libssl3 libgfortran5 libqt5gui5 libgomp1 libimath-3-1-29

RUN apt install -y libopenjp2-7 libopenvdb10.0 libgif7 libheif1 \
				  libdcmtk17 libfreetype6 bzip2 \
				  libopencolorio2.1 libwebp7 libwebpdemux2

# not sure if we need those ...
RUN apt install -y zlib1g liblz4-1 libpcre2-32-0 bison libxerces-c3.2


# set environment variables
ENV ALICEVISION_ROOT=/usr/local
ENV ALICEVISION_SENSOR_DB=/opt/AliceVisionData/cameraSensors.db
ENV ALICEVISION_VOCTREE=/opt/AliceVisionData/vlfeat_K80L3.SIFT.tree
ENV ALICEVISION_SPHERE_DETECTION_MODEL=/opt/AliceVisionData/sphereDetection_Mask-RCNN.onnx
ENV ALICEVISION_SEMANTIC_SEGMENTATION_MODEL=/opt/AliceVisionData/fcn_resnet50.onnx

ENV PYTHONPATH="/opt/Meshroom"

ENV QT_PLUGIN_PATH="/opt/QtAliceVision"
ENV QML2_IMPORT_PATH="/opt/QtAliceVision/qml"

# copy over additional AliceVision data
WORKDIR /opt/AliceVisionData
COPY --from=build_av /build_directory/AliceVision/AliceVision/src/aliceVision/sensorDB/cameraSensors.db .
COPY --from=download_av_data /AliceVisionData/vlfeat_K80L3.SIFT.tree \
							/AliceVisionData/sphereDetection_Mask-RCNN.onnx \
							/AliceVisionData/fcn_resnet50.onnx .

# copy over Meshroom
COPY --from=download_meshroom /opt/Meshroom /opt/Meshroom

# copy over python
COPY --from=build_python /usr/local /usr/local

# install Meshroom's python dependencies and missing plugin
WORKDIR /opt/Meshroom
RUN pip3 install -r requirements.txt
ADD https://drive.google.com/uc?export=download&id=1cTU7xrOsLI6ICgRSYz_t9E1lsrNF1kBB /usr/local/lib/python3.10/site-packages/PySide2/Qt/plugins/sceneparsers/libassimpsceneimport.so

# copy over cuda runtime
COPY --from=base_devel_with_cuda_runtime /usr/local/cuda-12.6 /usr/local/cuda-12.6

# copy over AliceVision
COPY --from=build_av /usr/local/bin /usr/local/bin
COPY --from=build_av /usr/local/include /usr/local/include
COPY --from=build_av /usr/local/lib /usr/local/lib
COPY --from=build_av /usr/local/libdata /usr/local/libdata
COPY --from=build_av /usr/local/share /usr/local/share

# copy over QtAliceVision
COPY --from=build_qtav /opt/QtAliceVision /opt/QtAliceVision

# create cuda symlinks
RUN ln -s /usr/local/cuda-12.6 /usr/local/cuda && \
    ln -s /usr/local/cuda-12.6 /usr/local/cuda-12

# need to tell linker where to find cuda libraries
COPY --from=base_devel_with_cuda_runtime /etc/ld.so.conf.d /etc/ld.so.conf.d
RUN ldconfig

# set up user
ARG username
WORKDIR /home/${username}
ENV XDG_CONFIG_HOME="/home/${username}/.config"

# replace root's home directory with the user's home directory
RUN rm -r /root
RUN ln -s /home/${username} /root

# run Meshroom when the container is started
ENTRYPOINT ["python3", "/opt/Meshroom/meshroom/ui"]
