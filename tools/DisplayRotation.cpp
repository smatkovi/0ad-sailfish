/* Copyright (C) 2026 Sebastian Matkovich
 * This file is part of 0 A.D.
 *
 * 0 A.D. is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * 0 A.D. is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with 0 A.D.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "precompiled.h"

#include "ps/DisplayRotation.h"

#include "ps/CLogger.h"
#include "ps/ConfigDB.h"

#include <cstdlib>
#include <utility>

namespace DisplayRotation
{

namespace
{

// -1 until the config has been consulted.
int g_Angle = -1;
int g_PhysicalWidth = 0, g_PhysicalHeight = 0;

/**
 * Turns a point of the physical surface into a point of the logical one.
 * The logical surface is the physical one with width and height exchanged.
 *
 * The two mappings are the inverses of the two UV orders used when blitting,
 * so a pixel tapped on the glass is the pixel the engine believes was tapped.
 */
void RotatePoint(const int angle, const float px, const float py, float& lx, float& ly)
{
	if (angle == 90)
	{
		lx = py;
		ly = static_cast<float>(g_PhysicalWidth) - px;
	}
	else
	{
		lx = static_cast<float>(g_PhysicalHeight) - py;
		ly = px;
	}
}

/**
 * Same for a relative movement, which has no origin to shift.
 */
void RotateVector(const int angle, const float dx, const float dy, float& ldx, float& ldy)
{
	if (angle == 90)
	{
		ldx = dy;
		ldy = -dx;
	}
	else
	{
		ldx = -dy;
		ldy = dx;
	}
}

} // anonymous namespace

int GetAngle()
{
	if (g_Angle < 0)
	{
		int angle = 0;
		if (const char* env = std::getenv("PYROGENESIS_DISPLAY_ROTATION"))
			angle = std::atoi(env);
		else
			angle = g_ConfigDB.Get("display.rotation", 0);

		if (angle != 90 && angle != 270)
		{
			if (angle != 0)
				LOGWARNING("Ignoring display.rotation=%d, only 0, 90 and 270 are supported", angle);
			angle = 0;
		}
		g_Angle = angle;
		if (g_Angle)
			LOGMESSAGE("Display is rotated by %d degrees", g_Angle);
	}
	return g_Angle;
}

void SetPhysicalSize(const int width, const int height)
{
	g_PhysicalWidth = width;
	g_PhysicalHeight = height;
}

void TransformEvent(SDL_Event& ev)
{
	const int angle = GetAngle();
	if (angle == 0 || g_PhysicalWidth <= 0 || g_PhysicalHeight <= 0)
		return;

	float x, y;
	switch (ev.type)
	{
	case SDL_MOUSEMOTION:
		RotatePoint(angle, ev.motion.x, ev.motion.y, x, y);
		ev.motion.x = static_cast<Sint32>(x);
		ev.motion.y = static_cast<Sint32>(y);
		RotateVector(angle, ev.motion.xrel, ev.motion.yrel, x, y);
		ev.motion.xrel = static_cast<Sint32>(x);
		ev.motion.yrel = static_cast<Sint32>(y);
		break;

	case SDL_MOUSEBUTTONDOWN:
	case SDL_MOUSEBUTTONUP:
		RotatePoint(angle, ev.button.x, ev.button.y, x, y);
		ev.button.x = static_cast<Sint32>(x);
		ev.button.y = static_cast<Sint32>(y);
		break;

	// Finger coordinates are normalised to the window, so the rotation is the
	// same one on a unit square.
	case SDL_FINGERDOWN:
	case SDL_FINGERUP:
	case SDL_FINGERMOTION:
		if (angle == 90)
		{
			x = ev.tfinger.y;
			y = 1.0f - ev.tfinger.x;
			ev.tfinger.x = x;
			ev.tfinger.y = y;
			x = ev.tfinger.dy;
			y = -ev.tfinger.dx;
		}
		else
		{
			x = 1.0f - ev.tfinger.y;
			y = ev.tfinger.x;
			ev.tfinger.x = x;
			ev.tfinger.y = y;
			x = -ev.tfinger.dy;
			y = ev.tfinger.dx;
		}
		ev.tfinger.dx = x;
		ev.tfinger.dy = y;
		break;

	case SDL_MULTIGESTURE:
		if (angle == 90)
		{
			x = ev.mgesture.y;
			y = 1.0f - ev.mgesture.x;
		}
		else
		{
			x = 1.0f - ev.mgesture.y;
			y = ev.mgesture.x;
		}
		ev.mgesture.x = x;
		ev.mgesture.y = y;
		// dTheta turns with the content; dDist is a length and does not.
		ev.mgesture.dTheta = -ev.mgesture.dTheta;
		break;

	// The mouse wheel reports scroll amounts, not a position - nothing to turn.

	case SDL_WINDOWEVENT:
		if (ev.window.event == SDL_WINDOWEVENT_RESIZED ||
			ev.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
		{
			SetPhysicalSize(ev.window.data1, ev.window.data2);
			std::swap(ev.window.data1, ev.window.data2);
		}
		break;
	}
}

} // namespace DisplayRotation
