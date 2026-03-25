#include "common.h"
#include "gui/GraphicsContext.h"
#include "gui/PaletteManager.h"
#include "gui/font/nitroFont2.h"
#include "core/math/RgbMixer.h"
#include "gui/OamBuilder.h"
#include "largeFolderIcon.h"
#include "gui/palette/GradientPalette.h"
#include "themes/IFontRepository.h"
#include "MaterialFileIcon.h"

namespace {

static bool nextUtf8CodePoint(const char*& text, char16_t& codePoint)
{
    const unsigned char* src = reinterpret_cast<const unsigned char*>(text);
    if (*src == 0)
        return false;

    if ((src[0] & 0x80) == 0)
    {
        codePoint = src[0];
        text += 1;
        return true;
    }
    if ((src[0] & 0xE0) == 0xC0 && src[1] != 0 && (src[1] & 0xC0) == 0x80)
    {
        codePoint = ((src[0] & 0x1F) << 6) | (src[1] & 0x3F);
        text += 2;
        return true;
    }
    if ((src[0] & 0xF0) == 0xE0 && src[1] != 0 && src[2] != 0 &&
        (src[1] & 0xC0) == 0x80 && (src[2] & 0xC0) == 0x80)
    {
        codePoint = ((src[0] & 0x0F) << 12) | ((src[1] & 0x3F) << 6) | (src[2] & 0x3F);
        text += 3;
        return true;
    }

    codePoint = '?';
    text += 1;
    return true;
}

static bool isAsciiAlphaNum(char16_t c)
{
    return (c >= u'0' && c <= u'9') ||
        (c >= u'A' && c <= u'Z') ||
        (c >= u'a' && c <= u'z');
}

}

MaterialFileIcon::MaterialFileIcon(const TCHAR* name, const MaterialColorScheme* materialColorScheme,
    const IFontRepository* fontRepository)
    : _materialColorScheme(materialColorScheme), _fontRepository(fontRepository)
{
    const char* text = name;
    char16_t first = 0;
    if (!nextUtf8CodePoint(text, first))
    {
        _displayName[0] = 0;
        return;
    }

    _displayName[0] = first;
    if (!isAsciiAlphaNum(first))
    {
        _displayName[1] = 0;
        return;
    }

    int i = 1;
    while (i < 3)
    {
        char16_t c = 0;
        const char* prev = text;
        if (!nextUtf8CodePoint(text, c))
            break;
        if (!isAsciiAlphaNum(c))
        {
            text = prev;
            break;
        }
        _displayName[i++] = c;
    }
    _displayName[i] = 0;
}

void MaterialFileIcon::UploadGraphics(vu16* vram)
{
    dma_ntrCopy32(3, GetIconTiles(), vram, 32 * 32 / 2);

    auto font = _fontRepository->GetFont(FontType::Medium11);
    u8 tileBuffer[32 * 16 / 2];
    memset(tileBuffer, 0, sizeof(tileBuffer));
    u32 textWidth, textHeight;
    nft2_measureString(font, _displayName, textWidth, textHeight);
    nft2_string_render_params_t renderParams;
    renderParams.x = ((int)32 - (int)textWidth) / 2;
    renderParams.y = 0;
    renderParams.width = 32;
    renderParams.height = 16;
    renderParams.a5i3 = false;
    nft2_renderString(font, _displayName, tileBuffer, 32, &renderParams);
    memcpy((u8*)vram + largeFolderIconTilesLen, tileBuffer, sizeof(tileBuffer));
}

void MaterialFileIcon::Draw(GraphicsContext& graphicsContext, const Rgb<8, 8, 8>& backgroundColor)
{
    auto iconColor = GetIconColor();
    auto nameColor = GetTextColor();

    auto oams = graphicsContext.GetOamManager().AllocOams(2);

    u32 iconPaletteRow = graphicsContext.GetPaletteManager().AllocRow(
        GradientPalette(backgroundColor, iconColor), _position.y, _position.y + 32);
    OamBuilder::OamWithSize<32, 32>(_position.x, _position.y, _vramOffset >> 7)
        .WithPalette16(iconPaletteRow)
        .WithPriority(graphicsContext.GetPriority())
        .Build(oams[1]);

    u32 namePaletteRow = graphicsContext.GetPaletteManager().AllocRow(
        GradientPalette(iconColor, nameColor), _position.y, _position.y + 32);
    OamBuilder::OamWithSize<32, 16>(_position.x, _position.y + GetTextYOffset(), (_vramOffset + largeFolderIconTilesLen) >> 7)
        .WithPalette16(namePaletteRow)
        .WithPriority(graphicsContext.GetPriority())
        .Build(oams[0]);
}
