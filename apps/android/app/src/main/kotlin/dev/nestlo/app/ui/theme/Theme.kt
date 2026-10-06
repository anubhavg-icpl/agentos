@file:OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)

package dev.nestlo.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import dev.nestlo.app.R

/** Nothing-style palette: OLED black, white, three grays, one red reserved for interrupts. */
object NColor {
    val Black = Color(0xFF000000)
    val White = Color(0xFFFFFFFF)
    val Gray90 = Color(0xFFE8E8E8)
    val Gray60 = Color(0xFF999999)
    val Gray40 = Color(0xFF666666)
    val Border = Color(0xFF222222)
    val BorderStrong = Color(0xFF333333)
    val Dot = Color(0xFF1C1C1C)

    /** Only for needs-input, errors and destructive actions. */
    val Red = Color(0xFFD71921)
}

private fun variable(res: Int, weight: Int) =
    Font(res, FontWeight(weight), variationSettings = FontVariation.Settings(FontVariation.weight(weight)))

/** Dot-matrix face: hero numbers and headlines only. */
val Doto = FontFamily(variable(R.font.doto, 400), variable(R.font.doto, 700), variable(R.font.doto, 900))

val SpaceGrotesk = FontFamily(
    variable(R.font.space_grotesk, 400),
    variable(R.font.space_grotesk, 500),
    variable(R.font.space_grotesk, 700),
)

val SpaceMono = FontFamily(
    Font(R.font.space_mono_regular, FontWeight.Normal),
    Font(R.font.space_mono_bold, FontWeight.Bold),
)

object NType {
    val Body = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 21.sp, color = NColor.Gray90)
    val BodyStrong = Body.copy(fontWeight = FontWeight.Medium, color = NColor.White)
    val Title = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Medium, fontSize = 20.sp, lineHeight = 26.sp, color = NColor.White)
    val Label = TextStyle(fontFamily = SpaceMono, fontWeight = FontWeight.Normal, fontSize = 11.sp, lineHeight = 14.sp, letterSpacing = 1.6.sp, color = NColor.Gray60)
    val Mono = TextStyle(fontFamily = SpaceMono, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 17.sp, color = NColor.Gray90)
    val Headline = TextStyle(fontFamily = Doto, fontWeight = FontWeight.Bold, fontSize = 28.sp, lineHeight = 32.sp, color = NColor.White)
    fun hero(size: Int) = TextStyle(fontFamily = Doto, fontWeight = FontWeight.Black, fontSize = size.sp, lineHeight = size.sp, color = NColor.White)
}

private val scheme = darkColorScheme(
    primary = NColor.White,
    onPrimary = NColor.Black,
    secondary = NColor.Gray90,
    onSecondary = NColor.Black,
    background = NColor.Black,
    onBackground = NColor.White,
    surface = NColor.Black,
    onSurface = NColor.White,
    surfaceVariant = NColor.Black,
    onSurfaceVariant = NColor.Gray60,
    outline = NColor.BorderStrong,
    outlineVariant = NColor.Border,
    error = NColor.Red,
    onError = NColor.White,
)

private val typography = Typography(
    bodyLarge = NType.Body,
    bodyMedium = NType.Body.copy(fontSize = 14.sp),
    bodySmall = NType.Body.copy(fontSize = 12.sp),
    titleLarge = NType.Title,
    titleMedium = NType.Title.copy(fontSize = 17.sp),
    labelLarge = NType.Label,
    labelMedium = NType.Label,
    labelSmall = NType.Label.copy(fontSize = 10.sp),
    headlineMedium = NType.Headline,
)

@Composable
fun NestloTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, typography = typography, content = content)
}
