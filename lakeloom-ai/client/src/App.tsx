import { createBrowserRouter, RouterProvider, NavLink, Outlet, useRouteError, isRouteErrorResponse } from 'react-router';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Skeleton,
} from '@databricks/appkit-ui/react';
import { Suspense, lazy } from 'react';

// ── Route-level code splitting ────────────────────────────────────────────────
// Each page is loaded on demand. Reduces initial bundle from ~1.7 MB to the
// shell + whichever page the user navigates to first.
const AnalyticsPage = lazy(() => import('./pages/analytics/AnalyticsPage').then(m => ({ default: m.AnalyticsPage })));
const LakebasePage = lazy(() => import('./pages/lakebase/LakebasePage').then(m => ({ default: m.LakebasePage })));
const FilesPage = lazy(() => import('./pages/files/FilesPage').then(m => ({ default: m.FilesPage })));

function PageLoader() {
  return (
    <div className="w-full max-w-2xl mx-auto space-y-4 mt-8">
      <Skeleton className="h-8 w-1/3" />
      <Skeleton className="h-64 w-full" />
    </div>
  );
}

const navLinkClass = ({ isActive }: { isActive: boolean }) =>
  `px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
    isActive
      ? 'bg-primary text-primary-foreground'
      : 'text-muted-foreground hover:bg-muted hover:text-foreground'
  }`;

function Layout() {
  return (
    <div className="min-h-screen bg-background flex flex-col">
      <header className="border-b px-6 py-3 flex items-center gap-4">
        <h1 className="text-lg font-semibold text-foreground">lakeloom-ai</h1>
        <nav className="flex gap-1">
          <NavLink to="/" end className={navLinkClass}>
            Home
          </NavLink>
          <NavLink to="/analytics" className={navLinkClass}>
            Analytics
          </NavLink>
          <NavLink to="/lakebase" className={navLinkClass}>
            Lakebase
          </NavLink>
          <NavLink to="/files" className={navLinkClass}>
            Files
          </NavLink>
        </nav>
      </header>

      <main className="flex-1 p-6">
        <Suspense fallback={<PageLoader />}>
          <Outlet />
        </Suspense>
      </main>
    </div>
  );
}

// ── Route-level error boundary ────────────────────────────────────────────────
// React Router v7 creates its own error boundary scope that supersedes the outer
// class-based ErrorBoundary in main.tsx. This component catches navigation errors,
// lazy-load failures, and unhandled throws from route loaders/actions/components.
function RouteErrorFallback() {
  const error = useRouteError();

  let title = 'Application Error';
  let message = 'An unexpected error occurred.';
  let stack: string | undefined;

  if (isRouteErrorResponse(error)) {
    title = `${error.status} ${error.statusText}`;
    message = typeof error.data === 'string' ? error.data : JSON.stringify(error.data);
  } else if (error instanceof Error) {
    message = error.message;
    stack = error.stack;
  } else if (typeof error === 'string') {
    message = error;
  }

  return (
    <div className="min-h-screen bg-background p-4">
      <Card className="max-w-2xl mx-auto mt-8">
        <CardHeader>
          <CardTitle className="text-destructive">{title}</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="space-y-4">
            <div>
              <h3 className="font-semibold mb-2">Error Message:</h3>
              <pre className="bg-muted p-3 rounded text-sm overflow-auto">{message}</pre>
            </div>
            {stack && (
              <div>
                <h3 className="font-semibold mb-2">Stack Trace:</h3>
                <pre className="bg-muted p-3 rounded text-sm overflow-auto max-h-96">{stack}</pre>
              </div>
            )}
            <button
              type="button"
              onClick={() => window.location.assign('/')}
              className="text-sm text-primary underline underline-offset-4 hover:text-primary/80"
            >
              Return to Home
            </button>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}

const router = createBrowserRouter([
  {
    element: <Layout />,
    errorElement: <RouteErrorFallback />,
    children: [
      { path: '/', element: <HomePage /> },
      { path: '/analytics', element: <AnalyticsPage /> },
      { path: '/lakebase', element: <LakebasePage /> },
      { path: '/files', element: <FilesPage /> },
    ],
  },
]);

export default function App() {
  return <RouterProvider router={router} />;
}

function HomePage() {
  return (
    <div className="max-w-2xl mx-auto space-y-6 mt-8">
      <div className="text-center">
        <h2 className="text-3xl font-bold mb-2 text-foreground">
          Welcome to your Databricks App
        </h2>
        <p className="text-lg text-muted-foreground">
          Powered by Databricks AppKit
        </p>
      </div>

      <Card className="shadow-lg">
        <CardHeader>
          <CardTitle>Getting Started</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <p className="text-sm text-muted-foreground">Your app is ready. Explore the resources below to continue building.</p>
          <ul className="space-y-2 text-sm">
            <li>
              <a
                href="https://github.com/databricks/appkit"
                target="_blank"
                rel="noopener noreferrer"
                className="text-primary underline underline-offset-4 hover:text-primary/80"
              >
                AppKit on GitHub →
              </a>
            </li>
            <li>
              <a
                href="https://databricks.github.io/appkit/"
                target="_blank"
                rel="noopener noreferrer"
                className="text-primary underline underline-offset-4 hover:text-primary/80"
              >
                AppKit documentation →
              </a>
            </li>
          </ul>
        </CardContent>
      </Card>
    </div>
  );
}
