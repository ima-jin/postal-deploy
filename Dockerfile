FROM ghcr.io/postalserver/postal:3.3.6@sha256:4f96b2e527c5589e6b73e25aebf877917bba45b460f535ecfca527488745e926

COPY --chown=postal:postal postal/ /opt/postal/app/
