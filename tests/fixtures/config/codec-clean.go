package x

// codec-clean holds the exact spec constraint set (R-codecclean)
// wave-B adds the no-transcode posture (inherit_codec=true, C3 extension)
const clean = `absolute_codec_string=OPUS,G722,PCMU,PCMA`
const secure = `rtp_secure_media=mandatory`
const notrans = `inherit_codec=true`
