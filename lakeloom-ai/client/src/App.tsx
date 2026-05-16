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
const ProjectsPage = lazy(() => import('./pages/projects/ProjectsPage').then(m => ({ default: m.ProjectsPage })));
const ProjectDetailPage = lazy(() => import('./pages/projects/ProjectDetailPage').then(m => ({ default: m.ProjectDetailPage })));
const CaptureDetailPage = lazy(() => import('./pages/projects/CaptureDetailPage').then(m => ({ default: m.CaptureDetailPage })));
const AnalyticsPage = lazy(() => import('./pages/analytics/AnalyticsPage').then(m => ({ default: m.AnalyticsPage })));
const LakebasePage = lazy(() => import('./pages/lakebase/LakebasePage').then(m => ({ default: m.LakebasePage })));
const FilesPage = lazy(() => import('./pages/files/FilesPage').then(m => ({ default: m.FilesPage })));
const PairingPage = lazy(() => import('./pages/pairing/PairingPage').then(m => ({ default: m.PairingPage })));

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
      ? 'bg-[var(--accent-primary,#FF3621)] text-white'
      : 'text-[var(--text-secondary,#5A6F77)] hover:bg-[var(--surface-tertiary,#EEEDE9)] hover:text-[var(--text-primary,#1B3139)]'
  }`;

function Layout() {
  return (
    <div className="min-h-screen bg-[var(--surface-primary,#fff)] flex flex-col">
      <header className="border-b border-[var(--border-default,#DCE0E2)] px-6 py-3 flex items-center gap-4">
        <h1 className="text-lg font-bold text-[var(--text-primary,#1B3139)]">lakeLoom</h1>
        <nav className="flex gap-1">
          <NavLink to="/" end className={navLinkClass}>
            Projects
          </NavLink>
          <NavLink to="/pairing" className={navLinkClass}>
            Pair iPhone
          </NavLink>
          <NavLink to="/files" className={navLinkClass}>
            Files
          </NavLink>
          <NavLink to="/analytics" className={navLinkClass}>
            Analytics
          </NavLink>
        </nav>
      </header>

      <main className="flex-1">
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
    <div className="min-h-screen bg-[var(--surface-primary,#fff)] p-4">
      <Card className="max-w-2xl mx-auto mt-8">
        <CardHeader>
          <CardTitle className="text-[var(--accent-error,#BD2B26)]">{title}</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="space-y-4">
            <div>
              <h3 className="font-semibold mb-2 text-[var(--text-primary,#1B3139)]">Error Message:</h3>
              <pre className="bg-[var(--surface-tertiary,#EEEDE9)] p-3 rounded text-sm overflow-auto">{message}</pre>
            </div>
            {stack && (
              <div>
                <h3 className="font-semibold mb-2 text-[var(--text-primary,#1B3139)]">Stack Trace:</h3>
                <pre className="bg-[var(--surface-tertiary,#EEEDE9)] p-3 rounded text-sm overflow-auto max-h-96">{stack}</pre>
              </div>
            )}
            <button
              type="button"
              onClick={() => window.location.assign('/')}
              className="text-sm text-[var(--accent-info,#2272B4)] underline underline-offset-4 hover:opacity-80"
            >
              Return to Projects
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
      { path: '/', element: <ProjectsPage /> },
      { path: '/projects/:id', element: <ProjectDetailPage /> },
      { path: '/projects/:id/captures/:cid', element: <CaptureDetailPage /> },
      { path: '/pairing', element: <PairingPage /> },
      { path: '/analytics', element: <AnalyticsPage /> },
      { path: '/lakebase', element: <LakebasePage /> },
      { path: '/files', element: <FilesPage /> },
    ],
  },
]);

export default function App() {
  return <RouterProvider router={router} />;
}
