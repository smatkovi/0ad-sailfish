#!/usr/bin/env python3
"""Wire the self-rotation (ps/DisplayRotation.*) into the 0 A.D. tree.

Idempotent: every edit is skipped if its marker is already present.
Run inside the build container with the tree root as argv[1].
"""
import sys, os

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/home/mersdk/0ad/0ad-0.28.0"

def edit(relpath, changes):
    path = os.path.join(ROOT, relpath)
    src = open(path).read()
    for marker, old, new in changes:
        if marker in src:
            print("  skip (already applied): %s" % marker)
            continue
        if old not in src:
            raise SystemExit("ANCHOR NOT FOUND in %s:\n%s" % (relpath, old))
        if src.count(old) != 1:
            raise SystemExit("ANCHOR AMBIGUOUS in %s (%d matches):\n%s"
                             % (relpath, src.count(old), old))
        src = src.replace(old, new)
        print("  applied: %s" % marker)
    open(path, "w").write(src)

# ---------------------------------------------------------------- VideoMode
edit("source/ps/VideoMode.cpp", [
    ("DisplayRotation.h",
     '#include "ps/CLogger.h"',
     '#include "ps/CLogger.h"\n#include "ps/DisplayRotation.h"'),
    ("SetPhysicalSize",
     "\tSDL_GetWindowSize(m_Window, &m_CurrentW, &m_CurrentH);",
     "\tSDL_GetWindowSize(m_Window, &m_CurrentW, &m_CurrentH);\n"
     "\t// Phone compositors only ever hand out a portrait surface. The engine\n"
     "\t// then works in a logical landscape one and turns the finished frame\n"
     "\t// when presenting it - see ps/DisplayRotation.h.\n"
     "\tDisplayRotation::SetPhysicalSize(m_CurrentW, m_CurrentH);\n"
     "\tif (DisplayRotation::IsActive())\n"
     "\t\tstd::swap(m_CurrentW, m_CurrentH);"),
])

# -------------------------------------------------------------------- input
edit("source/lib/input.cpp", [
    ("DisplayRotation.h",
     '#include "lib/status.h"',
     '#include "lib/status.h"\n#include "ps/DisplayRotation.h"'),
    ("TransformEvent",
     "int in_poll_event(SDL_Event_* event)\n"
     "{\n"
     "\treturn in_poll_priority_event(event) ? 1 : SDL_PollEvent(&event->ev);\n"
     "}",
     "int in_poll_event(SDL_Event_* event)\n"
     "{\n"
     "\tif (in_poll_priority_event(event))\n"
     "\t\treturn 1;\n"
     "\tif (!SDL_PollEvent(&event->ev))\n"
     "\t\treturn 0;\n"
     "\t// Only events straight out of SDL carry physical coordinates. The ones\n"
     "\t// the engine pushes itself - the touch layer synthesises mouse clicks -\n"
     "\t// are already logical and must not be turned a second time.\n"
     "\tDisplayRotation::TransformEvent(event->ev);\n"
     "\treturn 1;\n"
     "}"),
])

# ----------------------------------------------------------------- Device.h
edit("source/renderer/backend/gl/Device.h", [
    ("m_RotationAngle",
     "\tbool m_BackbufferAcquired = false;\n"
     "\tbool m_UseFramebufferInvalidating = false;",
     "\tbool m_BackbufferAcquired = false;\n"
     "\tbool m_UseFramebufferInvalidating = false;\n"
     "\n"
     "\t// Self-rotation for phone compositors, see ps/DisplayRotation.h. Zero\n"
     "\t// on every other platform, and then nothing below is ever touched.\n"
     "\tint m_RotationAngle = 0;\n"
     "\t// The real surface. m_SurfaceDrawable* hold the logical, turned size,\n"
     "\t// which is what the rest of the engine gets to see.\n"
     "\tint m_RealDrawableWidth = 0, m_RealDrawableHeight = 0;\n"
     "\tstd::unique_ptr<ITexture> m_RotatedColorTexture;\n"
     "\tstd::unique_ptr<ITexture> m_RotatedDepthStencilTexture;\n"
     "\tstd::unordered_map<\n"
     "\t\tBackbufferKey, std::unique_ptr<IFramebuffer>, BackbufferKeyHash> m_RotatedBackbuffers;\n"
     "\tstruct RotatedBlit\n"
     "\t{\n"
     "\t\tGLuint program = 0;\n"
     "\t\tGLuint vertexBuffer = 0;\n"
     "\t\tGLint textureLocation = -1;\n"
     "\t\tbool failed = false;\n"
     "\t} m_RotatedBlit;\n"
     "\n"
     "\tIFramebuffer* GetRotatedBackbuffer(const BackbufferKey& key);\n"
     "\tvoid CreateRotatedBlit();\n"
     "\tvoid DestroyRotatedBlit();\n"
     "\tvoid PresentRotated();"),
])

# --------------------------------------------------------------- Device.cpp
ROTATED_IMPL = r'''
namespace
{

// Turned blit of the logical backbuffer into the real surface. Deliberately
// plain GL rather than the backend's own pipeline: it runs between two frames,
// after CDeviceCommandContext::Flush, and must not disturb any cached state.
const char* const ROTATED_BLIT_VERTEX_SHADER =
	"attribute vec2 a_position;\n"
	"attribute vec2 a_uv;\n"
	"varying vec2 v_uv;\n"
	"void main()\n"
	"{\n"
	"	v_uv = a_uv;\n"
	"	gl_Position = vec4(a_position, 0.0, 1.0);\n"
	"}\n";

const char* const ROTATED_BLIT_FRAGMENT_SHADER =
	"#ifdef GL_ES\n"
	"precision mediump float;\n"
	"#endif\n"
	"varying vec2 v_uv;\n"
	"uniform sampler2D u_texture;\n"
	"void main()\n"
	"{\n"
	"	gl_FragColor = texture2D(u_texture, v_uv);\n"
	"}\n";

GLuint CompileRotatedBlitShader(const GLenum type, const char* source)
{
	const GLuint shader = glCreateShader(type);
	glShaderSource(shader, 1, &source, nullptr);
	glCompileShader(shader);
	GLint ok = 0;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok)
	{
		char log[1024] = {0};
		glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
		LOGERROR("Rotated blit shader failed to compile: %s", log);
		glDeleteShader(shader);
		return 0;
	}
	return shader;
}

} // anonymous namespace

void CDevice::CreateRotatedBlit()
{
	if (m_RotatedBlit.program || m_RotatedBlit.failed)
		return;
	m_RotatedBlit.failed = true;

	const GLuint vertexShader =
		CompileRotatedBlitShader(GL_VERTEX_SHADER, ROTATED_BLIT_VERTEX_SHADER);
	const GLuint fragmentShader =
		CompileRotatedBlitShader(GL_FRAGMENT_SHADER, ROTATED_BLIT_FRAGMENT_SHADER);
	if (!vertexShader || !fragmentShader)
		return;

	const GLuint program = glCreateProgram();
	glAttachShader(program, vertexShader);
	glAttachShader(program, fragmentShader);
	glBindAttribLocation(program, 0, "a_position");
	glBindAttribLocation(program, 1, "a_uv");
	glLinkProgram(program);
	// The shaders are referenced by the program now.
	glDeleteShader(vertexShader);
	glDeleteShader(fragmentShader);

	GLint ok = 0;
	glGetProgramiv(program, GL_LINK_STATUS, &ok);
	if (!ok)
	{
		char log[1024] = {0};
		glGetProgramInfoLog(program, sizeof(log) - 1, nullptr, log);
		LOGERROR("Rotated blit program failed to link: %s", log);
		glDeleteProgram(program);
		return;
	}

	// A triangle strip over the whole surface. The texture coordinates carry
	// the rotation: 90 degrees pairs with the compositor hint "landscape",
	// 270 with "inverted-landscape". Their inverses are what
	// DisplayRotation::TransformEvent does to incoming coordinates, so a pixel
	// touched on the glass is the pixel the engine believes was touched.
	const float positionX[4] = {-1.0f, 1.0f, -1.0f, 1.0f};
	const float positionY[4] = {-1.0f, -1.0f, 1.0f, 1.0f};
	float vertices[16];
	for (int i = 0; i < 4; ++i)
	{
		const float x = positionX[i], y = positionY[i];
		float u, v;
		if (m_RotationAngle == 90)
		{
			u = (1.0f - y) / 2.0f;
			v = (x + 1.0f) / 2.0f;
		}
		else
		{
			u = (y + 1.0f) / 2.0f;
			v = (1.0f - x) / 2.0f;
		}
		vertices[i * 4 + 0] = x;
		vertices[i * 4 + 1] = y;
		vertices[i * 4 + 2] = u;
		vertices[i * 4 + 3] = v;
	}

	GLuint vertexBuffer = 0;
	glGenBuffers(1, &vertexBuffer);
	GLint previousArrayBuffer = 0;
	glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &previousArrayBuffer);
	glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
	glBindBuffer(GL_ARRAY_BUFFER, previousArrayBuffer);

	m_RotatedBlit.program = program;
	m_RotatedBlit.vertexBuffer = vertexBuffer;
	m_RotatedBlit.textureLocation = glGetUniformLocation(program, "u_texture");
	m_RotatedBlit.failed = false;
	ogl_WarnIfError();
}

void CDevice::DestroyRotatedBlit()
{
	if (m_RotatedBlit.vertexBuffer)
		glDeleteBuffers(1, &m_RotatedBlit.vertexBuffer);
	if (m_RotatedBlit.program)
		glDeleteProgram(m_RotatedBlit.program);
	m_RotatedBlit = RotatedBlit{};
}

IFramebuffer* CDevice::GetRotatedBackbuffer(const BackbufferKey& key)
{
	// CTexture::Create binds through the active command context - and the very
	// first backbuffer is asked for while that context is still being built.
	// Those early requests are DONT_CARE binds, so handing out the real surface
	// costs nothing; the next Flush replaces it with the rotated one.
	if (!m_RotatedColorTexture && !m_ActiveCommandContext)
		return nullptr;

	if (!m_RotatedColorTexture)
	{
		const uint32_t width = m_SurfaceDrawableWidth;
		const uint32_t height = m_SurfaceDrawableHeight;
		const Sampler::Desc samplerDesc = Sampler::MakeDefaultSampler(
			Sampler::Filter::LINEAR, Sampler::AddressMode::CLAMP_TO_EDGE);
		m_RotatedColorTexture = CreateTexture2D("RotatedBackbufferColor",
			ITexture::Usage::SAMPLED | ITexture::Usage::COLOR_ATTACHMENT |
				ITexture::Usage::TRANSFER_SRC,
			Format::R8G8B8A8_UNORM, width, height, samplerDesc);
		// We never sample this one, we only need something to depth-test
		// against. GLES has no stencil texture format at all, so ask for a
		// combined buffer first and fall back to plain depth.
		const uint32_t depthStencilUsage = ITexture::Usage::DEPTH_STENCIL_ATTACHMENT;
		Format depthStencilFormat =
			GetPreferredDepthStencilFormat(depthStencilUsage, true, true);
		if (depthStencilFormat == Format::UNDEFINED)
			depthStencilFormat = GetPreferredDepthStencilFormat(depthStencilUsage, true, false);
		m_RotatedDepthStencilTexture = CreateTexture2D("RotatedBackbufferDepthStencil",
			depthStencilUsage, depthStencilFormat, width, height, samplerDesc);
	}

	auto it = m_RotatedBackbuffers.find(key);
	if (it == m_RotatedBackbuffers.end())
	{
		SColorAttachment colorAttachment{};
		colorAttachment.texture = m_RotatedColorTexture.get();
		colorAttachment.loadOp = std::get<0>(key);
		colorAttachment.storeOp = std::get<1>(key);
		colorAttachment.clearColor = CColor{0.0f, 0.0f, 0.0f, 1.0f};
		SDepthStencilAttachment depthStencilAttachment{};
		depthStencilAttachment.texture = m_RotatedDepthStencilTexture.get();
		depthStencilAttachment.loadOp = std::get<2>(key);
		depthStencilAttachment.storeOp = std::get<3>(key);
		it = m_RotatedBackbuffers.emplace(key, CreateFramebuffer(
			"RotatedBackbuffer", &colorAttachment, &depthStencilAttachment)).first;
	}
	return it->second.get();
}

void CDevice::PresentRotated()
{
	if (!m_RotatedColorTexture)
		return;
	CreateRotatedBlit();
	if (!m_RotatedBlit.program)
		return;

	PROFILE3("rotated blit");

	// Foreign GL code between two frames: save everything it touches. The
	// command context caches its pipeline state across the frame boundary and
	// would not notice a difference otherwise.
	GLint previousProgram = 0, previousArrayBuffer = 0, previousFramebuffer = 0;
	GLint previousActiveTexture = 0, previousTexture = 0;
	GLint previousViewport[4] = {0, 0, 0, 0};
	GLboolean previousColorMask[4] = {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE};
	GLint previousAttribEnabled[2] = {0, 0};
	glGetIntegerv(GL_CURRENT_PROGRAM, &previousProgram);
	glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &previousArrayBuffer);
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);
	glGetIntegerv(GL_ACTIVE_TEXTURE, &previousActiveTexture);
	glGetIntegerv(GL_VIEWPORT, previousViewport);
	glGetBooleanv(GL_COLOR_WRITEMASK, previousColorMask);
	const GLboolean previousDepthTest = glIsEnabled(GL_DEPTH_TEST);
	const GLboolean previousBlend = glIsEnabled(GL_BLEND);
	const GLboolean previousCullFace = glIsEnabled(GL_CULL_FACE);
	const GLboolean previousScissorTest = glIsEnabled(GL_SCISSOR_TEST);
	const GLboolean previousStencilTest = glIsEnabled(GL_STENCIL_TEST);
	for (GLuint index = 0; index < 2; ++index)
		glGetVertexAttribiv(index, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &previousAttribEnabled[index]);
	glActiveTexture(GL_TEXTURE0);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture);

	glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
	glViewport(0, 0, m_RealDrawableWidth, m_RealDrawableHeight);
	glDisable(GL_DEPTH_TEST);
	glDisable(GL_BLEND);
	glDisable(GL_CULL_FACE);
	glDisable(GL_SCISSOR_TEST);
	glDisable(GL_STENCIL_TEST);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

	glUseProgram(m_RotatedBlit.program);
	glBindBuffer(GL_ARRAY_BUFFER, m_RotatedBlit.vertexBuffer);
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);
	const GLsizei stride = 4 * sizeof(float);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, reinterpret_cast<const void*>(0));
	glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride,
		reinterpret_cast<const void*>(2 * sizeof(float)));
	glBindTexture(GL_TEXTURE_2D, m_RotatedColorTexture->As<CTexture>()->GetHandle());
	glUniform1i(m_RotatedBlit.textureLocation, 0);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

	for (GLuint index = 0; index < 2; ++index)
	{
		if (!previousAttribEnabled[index])
			glDisableVertexAttribArray(index);
	}
	glBindTexture(GL_TEXTURE_2D, previousTexture);
	glActiveTexture(previousActiveTexture);
	glBindBuffer(GL_ARRAY_BUFFER, previousArrayBuffer);
	glUseProgram(previousProgram);
	glColorMask(previousColorMask[0], previousColorMask[1], previousColorMask[2], previousColorMask[3]);
	if (previousStencilTest) glEnable(GL_STENCIL_TEST);
	if (previousScissorTest) glEnable(GL_SCISSOR_TEST);
	if (previousCullFace) glEnable(GL_CULL_FACE);
	if (previousBlend) glEnable(GL_BLEND);
	if (previousDepthTest) glEnable(GL_DEPTH_TEST);
	glViewport(previousViewport[0], previousViewport[1], previousViewport[2], previousViewport[3]);
	glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, previousFramebuffer);
	ogl_WarnIfError();
}

'''

edit("source/renderer/backend/gl/Device.cpp", [
    ("DisplayRotation.h",
     '#include "ps/ConfigDB.h"',
     '#include "ps/ConfigDB.h"\n#include "ps/DisplayRotation.h"\n#include "renderer/backend/Sampler.h"'),
    ("<utility>",
     "#include <SDL_config.h>",
     "#include <utility>\n\n#include <SDL_config.h>"),
    ("m_RealDrawableWidth =",
     "\t\tSDL_GL_GetDrawableSize(window, &device->m_SurfaceDrawableWidth, &device->m_SurfaceDrawableHeight);",
     "\t\tSDL_GL_GetDrawableSize(window, &device->m_SurfaceDrawableWidth, &device->m_SurfaceDrawableHeight);\n"
     "\t\tdevice->m_RealDrawableWidth = device->m_SurfaceDrawableWidth;\n"
     "\t\tdevice->m_RealDrawableHeight = device->m_SurfaceDrawableHeight;\n"
     "\t\t// Phone compositors only hand out portrait surfaces. Render landscape\n"
     "\t\t// into an offscreen framebuffer and turn it when presenting - see\n"
     "\t\t// ps/DisplayRotation.h. The engine above only sees the logical size.\n"
     "\t\tdevice->m_RotationAngle = DisplayRotation::GetAngle();\n"
     "\t\tif (device->m_RotationAngle != 0)\n"
     "\t\t\tstd::swap(device->m_SurfaceDrawableWidth, device->m_SurfaceDrawableHeight);"),
    ("DestroyRotatedBlit();",
     "\tif (m_Context)\n\t\tSDL_GL_DeleteContext(m_Context);",
     "\tm_RotatedBackbuffers.clear();\n"
     "\tm_RotatedColorTexture.reset();\n"
     "\tm_RotatedDepthStencilTexture.reset();\n"
     "\tDestroyRotatedBlit();\n"
     "\n"
     "\tif (m_Context)\n\t\tSDL_GL_DeleteContext(m_Context);"),
    ("GetRotatedBackbuffer(key)",
     "\tconst BackbufferKey key{\n"
     "\t\tcolorAttachmentLoadOp, colorAttachmentStoreOp,\n"
     "\t\tdepthStencilAttachmentLoadOp, depthStencilAttachmentStoreOp};\n"
     "\tauto it = m_Backbuffers.find(key);",
     "\tconst BackbufferKey key{\n"
     "\t\tcolorAttachmentLoadOp, colorAttachmentStoreOp,\n"
     "\t\tdepthStencilAttachmentLoadOp, depthStencilAttachmentStoreOp};\n"
     "\t// May still be nullptr while the command context is being created; the\n"
     "\t// real surface is the right answer then, see GetRotatedBackbuffer.\n"
     "\tif (m_RotationAngle != 0)\n"
     "\t{\n"
     "\t\tif (IFramebuffer* rotated = GetRotatedBackbuffer(key))\n"
     "\t\t\treturn rotated;\n"
     "\t}\n"
     "\tauto it = m_Backbuffers.find(key);"),
    ("PresentRotated();",
     "void CDevice::Present()\n"
     "{\n"
     "\tENSURE(m_BackbufferAcquired);\n"
     "\tm_BackbufferAcquired = false;\n",
     ROTATED_IMPL +
     "void CDevice::Present()\n"
     "{\n"
     "\tENSURE(m_BackbufferAcquired);\n"
     "\tm_BackbufferAcquired = false;\n"
     "\n"
     "\t// Put the logical landscape frame onto the real portrait surface.\n"
     "\tif (m_RotationAngle != 0)\n"
     "\t\tPresentRotated();\n"),
    ("m_RealDrawableWidth = height;",
     "\tm_Backbuffers.clear();\n"
     "\tm_SurfaceDrawableWidth = width;\n"
     "\tm_SurfaceDrawableHeight = height;",
     "\tm_Backbuffers.clear();\n"
     "\t// The framebuffers have to go before the textures they reference.\n"
     "\tm_RotatedBackbuffers.clear();\n"
     "\tm_RotatedColorTexture.reset();\n"
     "\tm_RotatedDepthStencilTexture.reset();\n"
     "\tm_SurfaceDrawableWidth = width;\n"
     "\tm_SurfaceDrawableHeight = height;\n"
     "\t// width and height are logical, so the real surface is the other way round.\n"
     "\tif (m_RotationAngle != 0)\n"
     "\t{\n"
     "\t\tm_RealDrawableWidth = height;\n"
     "\t\tm_RealDrawableHeight = width;\n"
     "\t}\n"
     "\telse\n"
     "\t{\n"
     "\t\tm_RealDrawableWidth = width;\n"
     "\t\tm_RealDrawableHeight = height;\n"
     "\t}"),
])

print("done")
