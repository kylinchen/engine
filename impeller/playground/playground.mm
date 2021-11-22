// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <sstream>

#include "flutter/fml/paths.h"
#include "flutter/testing/testing.h"
#include "impeller/image/compressed_image.h"
#include "impeller/playground/playground.h"
#include "impeller/renderer/allocator.h"
#include "impeller/renderer/backend/metal/context_mtl.h"
#include "impeller/renderer/backend/metal/texture_mtl.h"
#include "impeller/renderer/context.h"
#include "impeller/renderer/formats.h"
#include "impeller/renderer/render_pass.h"
#include "impeller/renderer/renderer.h"
#include "impeller/renderer/surface.h"

#define GLFW_INCLUDE_NONE
#import "third_party/glfw/include/GLFW/glfw3.h"
#define GLFW_EXPOSE_NATIVE_COCOA
#import "third_party/glfw/include/GLFW/glfw3native.h"

#include <Metal/Metal.h>
#include <QuartzCore/QuartzCore.h>

namespace impeller {

static std::string ShaderLibraryDirectory() {
  auto path_result = fml::paths::GetExecutableDirectoryPath();
  if (!path_result.first) {
    return {};
  }
  return fml::paths::JoinPaths({path_result.second, "shaders"});
}

static std::vector<std::string> ShaderLibraryPathsForPlayground() {
  std::vector<std::string> paths;
  paths.emplace_back(fml::paths::JoinPaths(
      {ShaderLibraryDirectory(), "shader_fixtures.metallib"}));
  paths.emplace_back(
      fml::paths::JoinPaths({fml::paths::GetExecutableDirectoryPath().second,
                             "shaders", "entity.metallib"}));
  return paths;
}

Playground::Playground()
    : renderer_(
          std::make_shared<ContextMTL>(ShaderLibraryPathsForPlayground())) {}

Playground::~Playground() = default;

std::shared_ptr<Context> Playground::GetContext() const {
  return renderer_.IsValid() ? renderer_.GetContext() : nullptr;
}

static void PlaygroundKeyCallback(GLFWwindow* window,
                                  int key,
                                  int scancode,
                                  int action,
                                  int mods) {
  if ((key == GLFW_KEY_ESCAPE || key == GLFW_KEY_Q) && action == GLFW_RELEASE) {
    ::glfwSetWindowShouldClose(window, GLFW_TRUE);
  }
}

static std::string GetWindowTitle(const std::string& test_name) {
  std::stringstream stream;
  stream << "Impeller Playground for '" << test_name
         << "' (Press ESC or 'q' to quit)";
  return stream.str();
}

Point Playground::GetCursorPosition() const {
  return cursor_position_;
}

ISize Playground::GetWindowSize() const {
  return {1024, 768};
}

void Playground::SetCursorPosition(Point pos) {
  cursor_position_ = pos;
}

bool Playground::OpenPlaygroundHere(Renderer::RenderCallback render_callback) {
  if (!render_callback) {
    return true;
  }

  if (!renderer_.IsValid()) {
    return false;
  }

  if (::glfwInit() != GLFW_TRUE) {
    return false;
  }
  fml::ScopedCleanupClosure terminate([]() { ::glfwTerminate(); });

  ::glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
  // Recreation of the target render buffer is not setup in the playground yet.
  // So prevent users from resizing and getting confused that their math is
  // wrong.
  ::glfwWindowHint(GLFW_RESIZABLE, false);

  auto window_title = GetWindowTitle(flutter::testing::GetCurrentTestName());
  auto window =
      ::glfwCreateWindow(GetWindowSize().width, GetWindowSize().height,
                         window_title.c_str(), NULL, NULL);
  if (!window) {
    return false;
  }

  ::glfwSetWindowUserPointer(window, this);
  ::glfwSetKeyCallback(window, &PlaygroundKeyCallback);
  ::glfwSetCursorPosCallback(window, [](GLFWwindow* window, double x,
                                        double y) {
    reinterpret_cast<Playground*>(::glfwGetWindowUserPointer(window))
        ->SetCursorPosition({static_cast<Scalar>(x), static_cast<Scalar>(y)});
  });

  fml::ScopedCleanupClosure close_window(
      [window]() { ::glfwDestroyWindow(window); });

  NSWindow* cocoa_window = ::glfwGetCocoaWindow(window);
  CAMetalLayer* layer = [CAMetalLayer layer];
  layer.device = ContextMTL::Cast(*renderer_.GetContext()).GetMTLDevice();
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  cocoa_window.contentView.layer = layer;
  cocoa_window.contentView.wantsLayer = YES;

  while (true) {
    ::glfwWaitEventsTimeout(1.0 / 30.0);

    if (::glfwWindowShouldClose(window)) {
      return true;
    }

    auto current_drawable = [layer nextDrawable];

    if (!current_drawable) {
      FML_LOG(ERROR) << "Could not acquire current drawable.";
      return false;
    }

    TextureDescriptor color0_tex;
    color0_tex.format = PixelFormat::kB8G8R8A8UNormInt;
    color0_tex.size = {
        static_cast<ISize::Type>(current_drawable.texture.width),
        static_cast<ISize::Type>(current_drawable.texture.height)};
    color0_tex.usage = static_cast<uint64_t>(TextureUsage::kRenderTarget);

    ColorAttachment color0;
    color0.texture =
        std::make_shared<TextureMTL>(color0_tex, current_drawable.texture);
    color0.clear_color = Color::SkyBlue();
    color0.load_action = LoadAction::kClear;
    color0.store_action = StoreAction::kStore;

    TextureDescriptor stencil0_tex;
    stencil0_tex.format = PixelFormat::kD32FloatS8UNormInt;
    stencil0_tex.size = color0_tex.size;
    stencil0_tex.usage =
        static_cast<TextureUsageMask>(TextureUsage::kRenderTarget);
    auto stencil_texture =
        renderer_.GetContext()->GetPermanentsAllocator()->CreateTexture(
            StorageMode::kDeviceTransient, stencil0_tex);
    stencil_texture->SetLabel("PlaygroundMainStencil");

    StencilAttachment stencil0;
    stencil0.texture = stencil_texture;
    stencil0.clear_stencil = 0;
    stencil0.load_action = LoadAction::kClear;
    stencil0.store_action = StoreAction::kDontCare;

    RenderTarget desc;
    desc.SetColorAttachment(color0, 0u);
    desc.SetStencilAttachment(stencil0);

    Surface surface(desc);

    Renderer::RenderCallback wrapped_callback = [render_callback](auto& pass) {
      pass.SetLabel("Playground Main Render Pass");
      return render_callback(pass);
    };

    if (!renderer_.Render(surface, wrapped_callback)) {
      FML_LOG(ERROR) << "Could not render into the surface.";
      return false;
    }

    [current_drawable present];
  }

  return true;
}

std::shared_ptr<Texture> Playground::CreateTextureForFixture(
    const char* fixture_name) const {
  CompressedImage compressed_image(
      flutter::testing::OpenFixtureAsMapping(fixture_name));
  // The decoded image is immediately converted into RGBA as that format is
  // known to be supported everywhere. For image sources that don't need 32 bit
  // pixel strides, this is overkill. Since this is a test fixture we aren't
  // necessarily trying to eke out memory savings here and instead favor
  // simplicity.
  auto image = compressed_image.Decode().ConvertToRGBA();
  if (!image.IsValid()) {
    FML_LOG(ERROR) << "Could not find fixture named " << fixture_name;
    return nullptr;
  }

  auto texture_descriptor = TextureDescriptor{};
  texture_descriptor.format = PixelFormat::kR8G8B8A8UNormInt;
  texture_descriptor.size = image.GetSize();
  texture_descriptor.mip_count = 1u;

  auto texture =
      renderer_.GetContext()->GetPermanentsAllocator()->CreateTexture(
          StorageMode::kHostVisible, texture_descriptor);
  if (!texture) {
    FML_LOG(ERROR) << "Could not allocate texture for fixture " << fixture_name;
    return nullptr;
  }
  texture->SetLabel(fixture_name);

  auto uploaded = texture->SetContents(image.GetAllocation()->GetMapping(),
                                       image.GetAllocation()->GetSize());
  if (!uploaded) {
    FML_LOG(ERROR) << "Could not upload texture to device memory for fixture "
                   << fixture_name;
    return nullptr;
  }
  return texture;
}

}  // namespace impeller