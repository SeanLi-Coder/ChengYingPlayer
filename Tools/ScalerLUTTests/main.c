// Isolate scaler-LUT interpolation using synthetic data and real Apple software GL.
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLRenderers.h>
#include <OpenGL/gl3.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Generated from the repository's actual backport patch, not a copied algorithm.
#include "scaler_lut_patch.h"

enum { LUT_ROWS = 256, LUT_STRIDE = 8, TAPS = 6, COMPONENTS = 4,
       OUTPUT_WIDTH = 2, OUTPUT_HEIGHT = 4, OUTPUT_FLOATS = 32 };
static const float valid_weights[TAPS] = {
    0.03125f, -0.125f, 0.59375f, 0.59375f, -0.125f, 0.03125f,
};

static bool check_gl(const char *operation) {
    GLenum error = glGetError();
    if (error == GL_NO_ERROR)
        return true;
    fprintf(stderr, "FAIL: %s returned GL error 0x%x\n", operation, error);
    return false;
}

static void json_float(float value) {
    if (isnan(value))
        printf("\"NaN\"");
    else if (isinf(value))
        printf(signbit(value) ? "\"-Inf\"" : "\"+Inf\"");
    else
        printf("%.9g", (double)value);
}

static void print_pixels(const char *test_case, const float pixels[OUTPUT_FLOATS]) {
    for (int row = 0; row < OUTPUT_HEIGHT; row++) {
        for (int column = 0; column < OUTPUT_WIDTH; column++) {
            printf("{\"type\":\"sample\",\"case\":\"%s\",\"phase\":%.2f,"
                   "\"column\":%d,\"rgba\":[", test_case, row * 0.25, column);
            for (int component = 0; component < COMPONENTS; component++) {
                if (component)
                    putchar(',');
                json_float(pixels[(row * OUTPUT_WIDTH + column) * COMPONENTS + component]);
            }
            puts("]}");
        }
    }
}

static bool matches(float actual, float expected) {
    // Identical rows and binary-exact coefficients need no rounding tolerance.
    return isfinite(actual) && actual == expected;
}

static bool valid_taps_match(const float pixels[OUTPUT_FLOATS]) {
    for (int row = 0; row < OUTPUT_HEIGHT; row++) {
        for (int tap = 0; tap < TAPS; tap++) {
            if (!matches(pixels[row * LUT_STRIDE + tap], valid_weights[tap]))
                return false;
        }
    }
    return true;
}

static unsigned poisoned_valid_lanes(const float pixels[OUTPUT_FLOATS]) {
    unsigned count = 0;
    for (int row = 0; row < OUTPUT_HEIGHT; row++) {
        // These are real taps 2 and 3 in the first texel, not padding lanes.
        for (int component = 2; component < 4; component++)
            count += !isfinite(pixels[row * LUT_STRIDE + component]);
    }
    return count;
}

static void initialize_lut(float *weights, float poison) {
    for (int row = 0; row < LUT_ROWS; row++) {
        for (int tap = 0; tap < TAPS; tap++)
            weights[row * LUT_STRIDE + tap] = valid_weights[tap];
        weights[row * LUT_STRIDE + 6] = poison;
        weights[row * LUT_STRIDE + 7] = poison;
    }
}

static bool supports_extension(const char *wanted) {
    GLint count = 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, &count);
    for (GLint index = 0; index < count; index++) {
        const char *name = (const char *)glGetStringi(GL_EXTENSIONS, (GLuint)index);
        if (name && strcmp(name, wanted) == 0)
            return true;
    }
    return false;
}

static GLuint compile_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    if (!shader)
        return 0;
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char message[4096] = {0};
        glGetShaderInfoLog(shader, sizeof(message), NULL, message);
        fprintf(stderr, "FAIL: Synthetic shader compilation: %s\n", message);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint create_program(void) {
    const char *vertex_source =
        "#version 150\n"
        "void main() {\n"
        "  vec2 vertices[3] = vec2[3](vec2(-1.0, -1.0),\n"
        "      vec2(3.0, -1.0), vec2(-1.0, 3.0));\n"
        "  gl_Position = vec4(vertices[gl_VertexID], 0.0, 1.0);\n"
        "}\n";
    const char *fragment_source =
        "#version 150\n"
        "uniform sampler2D lut;\n"
        "out vec4 out_color;\n"
        "void main() {\n"
        "  float fcoord = floor(gl_FragCoord.y) * 0.25;\n"
        "  float ypos = mix(0.5 / 256.0, 1.0 - 0.5 / 256.0, fcoord);\n"
        "  out_color = texture(lut, vec2(gl_FragCoord.x * 0.5, ypos));\n"
        "}\n";
    GLuint vertex = compile_shader(GL_VERTEX_SHADER, vertex_source);
    GLuint fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
    if (!vertex || !fragment) {
        if (vertex) glDeleteShader(vertex);
        if (fragment) glDeleteShader(fragment);
        return 0;
    }
    GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glBindFragDataLocation(program, 0, "out_color");
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char message[4096] = {0};
        glGetProgramInfoLog(program, sizeof(message), NULL, message);
        fprintf(stderr, "FAIL: Synthetic shader linking: %s\n", message);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

static bool upload_and_verify(GLuint lut, const float weights[LUT_ROWS * LUT_STRIDE]) {
    float downloaded[LUT_ROWS * LUT_STRIDE];
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, lut);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, 2, LUT_ROWS, 0,
                 GL_RGBA, GL_FLOAT, weights);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_FLOAT, downloaded);
    if (!check_gl("Upload and read the RGBA32F LUT"))
        return false;
    for (int index = 0; index < LUT_ROWS * LUT_STRIDE; index++) {
        float wanted = weights[index], actual = downloaded[index];
        bool equal = isnan(wanted) ? isnan(actual) : actual == wanted;
        if (!equal) {
            fprintf(stderr, "FAIL: LUT upload changed component %d\n", index);
            return false;
        }
    }
    return true;
}

static bool sample(GLuint program, GLuint lut, GLuint fbo, GLenum filter,
                   const char *test_case, float pixels[OUTPUT_FLOATS]) {
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, lut);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (GLint)filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (GLint)filter);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glDrawBuffer(GL_COLOR_ATTACHMENT0);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    glViewport(0, 0, OUTPUT_WIDTH, OUTPUT_HEIGHT);
    glUseProgram(program);
    GLint location = glGetUniformLocation(program, "lut");
    if (location < 0) {
        fputs("FAIL: Synthetic LUT sampler was not linked\n", stderr);
        return false;
    }
    glUniform1i(location, 0);
    glClearColor(0.25f, 0.25f, 0.25f, 0.25f);
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    if (!check_gl("Draw the LUT sampling shader"))
        return false;
    // A normal client-memory read synchronizes the tiny draw; no CA layer or swap.
    glReadPixels(0, 0, OUTPUT_WIDTH, OUTPUT_HEIGHT, GL_RGBA, GL_FLOAT, pixels);
    if (!check_gl("Read the RGBA32F sampling output"))
        return false;
    print_pixels(test_case, pixels);
    return true;
}

int main(void) {
    CGLPixelFormatObj pixel_format = NULL;
    CGLContextObj context = NULL;
    bool context_current = false;
    GLuint lut = 0, output = 0, fbo = 0, program = 0, vao = 0;
    int exit_code = 1;
    unsigned negative_lanes = 0;
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID,
        (CGLPixelFormatAttribute)0,
    };
    GLint format_count = 0;
    CGLError result = CGLChoosePixelFormat(attributes, &pixel_format, &format_count);
    if (result != kCGLNoError || !pixel_format || format_count < 1) {
        fputs("FAIL: Apple software OpenGL pixel format unavailable\n", stderr);
        goto finished;
    }
    result = CGLCreateContext(pixel_format, NULL, &context);
    if (result != kCGLNoError || !context || CGLSetCurrentContext(context) != kCGLNoError) {
        fputs("FAIL: Apple software OpenGL context unavailable\n", stderr);
        goto finished;
    }
    context_current = true;
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    if (!renderer || !strstr(renderer, "Apple Software Renderer")) {
        fputs("FAIL: The requested Apple software renderer is not active\n", stderr);
        goto finished;
    }
    printf("INFO: GL renderer=%s, version=%s\n", renderer, glGetString(GL_VERSION));
    // Isolate the upload/readback contract; do not depend on external GL state.
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    if (supports_extension("GL_APPLE_client_storage"))
        glPixelStorei((GLenum)0x85B2, GL_FALSE);
    glDisable(GL_DITHER);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_SCISSOR_TEST);
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    program = create_program();
    if (!program || !check_gl("Initialize the synthetic shader"))
        goto finished;
    glGenTextures(1, &lut);
    glBindTexture(GL_TEXTURE_2D, lut);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenTextures(1, &output);
    glBindTexture(GL_TEXTURE_2D, output);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, OUTPUT_WIDTH, OUTPUT_HEIGHT, 0,
                 GL_RGBA, GL_FLOAT, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, output, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE ||
        !check_gl("Create the RGBA32F output framebuffer")) {
        fputs("FAIL: RGBA32F output framebuffer is incomplete\n", stderr);
        goto finished;
    }

    float weights[LUT_ROWS * LUT_STRIDE];
    float pixels[OUTPUT_FLOATS];
    initialize_lut(weights, 0.0f);
    if (!upload_and_verify(lut, weights) ||
        !sample(program, lut, fbo, GL_LINEAR, "finite_baseline", pixels) ||
        !valid_taps_match(pixels)) {
        fputs("FAIL: Finite baseline did not preserve all six coefficients\n", stderr);
        goto finished;
    }

    const float poisons[] = {NAN, INFINITY, -INFINITY};
    const char *names[] = {"nan", "positive_inf", "negative_inf"};
    for (unsigned test = 0; test < sizeof(poisons) / sizeof(poisons[0]); test++) {
        char label[64];
        initialize_lut(weights, poisons[test]);
        if (!upload_and_verify(lut, weights))
            goto finished;
        snprintf(label, sizeof(label), "nearest_%s", names[test]);
        if (!sample(program, lut, fbo, GL_NEAREST, label, pixels) ||
            !valid_taps_match(pixels)) {
            fputs("FAIL: Nearest control did not preserve the valid coefficients\n", stderr);
            goto finished;
        }
        snprintf(label, sizeof(label), "linear_poison_%s", names[test]);
        if (!sample(program, lut, fbo, GL_LINEAR, label, pixels))
            goto finished;
        unsigned poisoned = poisoned_valid_lanes(pixels);
        negative_lanes += poisoned;
        printf("{\"type\":\"negative_control\",\"poison\":\"%s\","
               "\"poisoned_valid_lanes\":%u,\"reproduced\":%s}\n",
               names[test], poisoned, poisoned ? "true" : "false");

        apply_repository_padding_patch(weights, LUT_ROWS, LUT_STRIDE, TAPS, COMPONENTS);
        // The algorithm is extracted from the actual patch; this is its contract.
        for (int row = 0; row < LUT_ROWS; row++) {
            for (int component = 0; component < LUT_STRIDE; component++) {
                float wanted = valid_weights[component < TAPS ? component : component - COMPONENTS];
                if (weights[row * LUT_STRIDE + component] != wanted) {
                    fputs("FAIL: Extracted patch changed a valid coefficient or missed padding\n", stderr);
                    goto finished;
                }
            }
        }
        if (!upload_and_verify(lut, weights))
            goto finished;
        snprintf(label, sizeof(label), "linear_corrected_%s", names[test]);
        if (!sample(program, lut, fbo, GL_LINEAR, label, pixels) ||
            !valid_taps_match(pixels)) {
            fputs("FAIL: Corrected LUT did not preserve all six coefficients\n", stderr);
            goto finished;
        }
        for (int row = 0; row < OUTPUT_HEIGHT; row++) {
            if (!matches(pixels[row * LUT_STRIDE + 6], valid_weights[2]) ||
                !matches(pixels[row * LUT_STRIDE + 7], valid_weights[3])) {
                fputs("FAIL: Corrected padding did not remain finite and replicated\n", stderr);
                goto finished;
            }
        }
    }
    exit_code = negative_lanes ? 0 : 77;

finished:
    if (context_current) {
        glUseProgram(0);
        if (program) glDeleteProgram(program);
        if (vao) glDeleteVertexArrays(1, &vao);
        if (fbo) glDeleteFramebuffers(1, &fbo);
        if (output) glDeleteTextures(1, &output);
        if (lut) glDeleteTextures(1, &lut);
        if (!check_gl("Delete the synthetic GL objects"))
            exit_code = 1;
        if (CGLSetCurrentContext(NULL) != kCGLNoError) {
            fputs("FAIL: Clear the current synthetic CGL context\n", stderr);
            exit_code = 1;
        }
    }
    if (context && CGLDestroyContext(context) != kCGLNoError) {
        fputs("FAIL: Destroy the synthetic CGL context\n", stderr);
        exit_code = 1;
    }
    if (pixel_format && CGLDestroyPixelFormat(pixel_format) != kCGLNoError) {
        fputs("FAIL: Destroy the synthetic CGL pixel format\n", stderr);
        exit_code = 1;
    }
    printf("{\"type\":\"result\",\"outcome\":\"%s\","
           "\"negative_reproduced\":%s,\"corrected_valid\":%s,"
           "\"poisoned_valid_lanes\":%u}\n",
           exit_code == 0 ? "passed" : exit_code == 77 ? "not_applicable" : "failed",
           negative_lanes ? "true" : "false", exit_code == 1 ? "false" : "true", negative_lanes);
    return exit_code;
}
