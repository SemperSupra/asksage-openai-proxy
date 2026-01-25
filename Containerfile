# OpenShift / RHEL9 friendly container build.
# Uses Red Hat UBI python image so it runs well under Podman and OpenShift.
FROM registry.access.redhat.com/ubi9/python-311:latest

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /opt/app

# Install deps
COPY requirements.txt /opt/app/requirements.txt
RUN pip install --upgrade pip && pip install -r requirements.txt

# Copy app
COPY app/ /opt/app/app/

# OpenShift runs containers with an arbitrary UID. Make sure the app dir is readable.
RUN chgrp -R 0 /opt/app && chmod -R g=u /opt/app

EXPOSE 8000

# Non-root by default (OpenShift will override with a random UID anyway)
USER 1001

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
